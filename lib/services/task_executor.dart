import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'ai_service.dart';
import 'screen_automation_service.dart';
import 'app_launcher_service.dart';
import 'notification_service.dart';
import 'task_history_logger.dart';
import 'shizuku_service.dart';
import 'skill_memory_service.dart';
import 'recovery_engine.dart';
import '../models/saved_skill.dart';

class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;
  final NotificationService _notificationService = NotificationService();
  final SkillMemoryService _skillMemory = SkillMemoryService();
  final RecoveryEngine _recoveryEngine = RecoveryEngine();

  final void Function(String message)? onProgress;

  bool _cancelled = false;
  Completer<void>? _cancelCompleter;

  TaskExecutor({
    required AiService aiService,
    required ScreenAutomationService screenService,
    required AppLauncherService appLauncher,
    required ShizukuService shizukuService,
    this.onProgress,
  }) : _aiService = aiService,
       _screenService = screenService,
       _appLauncher = appLauncher,
       _shizukuService = shizukuService;

  void cancel() {
    _cancelled = true;
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  static const String _taskSystemPrompt = '''
You are a FAST phone automation agent. Your goal is to complete the TASK in the FEWEST steps possible.
You are given the current SCREEN content and a TASK.

Respond with ONLY a JSON object (no markdown):
{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "brief reason",
  "is_complete": false
}

Available actions:
- click_text: {"text": "exact text to click"}
- click_at: {"x": 540, "y": 960}
- type_text: {"text": "hello"}
- press_enter: {}
- scroll: {"direction": "down"} (Max 3 scrolls total)
- swipe: {"startX": 540, "startY": 2000, "endX": 540, "endY": 500}
- press_back: {}
- press_home: {}
- open_app: {"app_name": "WhatsApp"}
- open_package: {"package_name": "com.bykea.partner"}
- wait: {}
- done: {}

CRITICAL RULES FOR SPEED:
1. PLAN AHEAD: Do not waste steps. If you need to open an app and search, do it directly.
2. NO WASTED STEPS: Do not scroll aimlessly. If you cannot find something in 2 scrolls, use click_at with coordinates or open a different app.
3. NO REPEATING: If an action fails, DO NOT repeat it. Try a completely different approach (e.g., if click_text fails, use click_at).
4. If an app opens but doesn't load, wait one step, then try again. Do not close and reopen unless it crashes.
5. Set is_complete=true ONLY when the task is 100% done.
6. Keep reasoning to 3-4 words max.
7. If you are stuck after 5 steps, set is_complete=true and explain why in reasoning.
8. When asked to open a specific app, prefer open_package with the exact package name (e.g., com.bykea.partner, com.termux, com.android.chrome).
''';

  String _extractJson(String text) {
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) {
      return match.group(1)!;
    }

    final startIndex = text.indexOf('{');
    final endIndex = text.lastIndexOf('}');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return text.substring(startIndex, endIndex + 1);
    }

    return text.trim();
  }

  Future<String> executeTask(String userGoal) async {
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] executeTask() CALLED with goal: $userGoal",
    );
    _cancelled = false;

    await ScreenAutomationService.logToNative(
      "[TaskExecutor] Checking if accessibility service is running...",
    );
    final isRunning = await _screenService.isServiceRunning();
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] Accessibility service isRunning = $isRunning",
    );
    if (!isRunning) {
      await ScreenAutomationService.logToNative(
        "[TaskExecutor] Accessibility service not running, returning early.",
      );
      return 'Accessibility service is not enabled. Go to Settings \u2192 Accessibility \u2192 PrivateAgent Screen Control and enable it.';
    }

    final results = <String>[];
    results.add('Starting task: $userGoal');
    _report('Starting task: $userGoal');

    final savedSkill = await _skillMemory.findSkill(userGoal);
    if (savedSkill != null && savedSkill.isReliable) {
      _report(
        'Found saved skill! Replaying ${savedSkill.steps.length} steps...',
      );
      final replaySuccess = await _replaySkill(savedSkill, results);
      if (replaySuccess) {
        results.add('Task complete via skill memory.');
        _report('Task complete (via skill memory).');
        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          'Agent finished its goal using memory.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Success',
          0,
          savedSkill.steps.length,
          results,
        );
        await _screenService.showToast('Task Complete! (Memory)');
        return 'Done.';
      } else {
        _report('Replay failed, falling back to AI...');
        await _skillMemory.recordFailure(savedSkill.id);
      }
    }

    final shortcut = _getNavigationShortcut(userGoal);
    String lastAction = '';
    int sameActionCount = 0;
    int consecutiveFailures = 0;
    String lastFailedAction = '';
    int totalTokens = 0;
    final List<ActionStep> executedSteps = [];

    if (shortcut != null && shortcut.isNotEmpty) {
      results.add('Using navigation shortcut: ${shortcut.length} steps');
      _report('Using navigation shortcut...');
      for (final step in shortcut) {
        if (_cancelled) break;

        bool success = false;
        if (step.action == 'open_app') {
          final appName = step.params['app_name'] as String? ?? '';
          final res = await _appLauncher.openApp(appName);
          success = res.startsWith('Opened');
          await Future.delayed(const Duration(milliseconds: 3000));
        } else if (step.action == 'click_text') {
          final text = step.params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          await Future.delayed(const Duration(milliseconds: 1500));
        }

        if (success) {
          executedSteps.add(step);
          lastAction = step.action;
        } else {
          break;
        }
      }
    } else {
      final currentPkg = await _screenService.getCurrentPackage();
      if (currentPkg == 'com.orailnoor.privateagent') {
        _report('Moving to background...');
        await _screenService.pressHome();
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }

    for (int step = 0; step < _aiService.maxSteps; step++) {
      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notificationService.showTaskCompleteNotification(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('Task Cancelled');
        return 'Task cancelled.';
      }

      int delay = 1200;
      if (lastAction == 'open_app' || lastAction == 'open_package') {
        delay = 3000;
      } else if (lastAction == 'type_text') {
        delay = 2000;
      } else if (lastAction == 'click_text' || lastAction == 'click_at') {
        delay = 1500;
      } else if (lastAction == 'scroll') {
        delay = 1000;
      }
      await Future.delayed(Duration(milliseconds: delay));

      final screenContent = _aiService.useScreenCompression
          ? await _screenService.getCompressedScreenDescription(userGoal)
          : await _screenService.getScreenDescription();
      developer.log(
        '=== SCREEN DUMP (Step ${step + 1}) ===\n$screenContent',
        name: 'PrivateAgent',
      );

      final prevResultStr = step > 0 && results.isNotEmpty
          ? '\nPREVIOUS ACTION RESULT: ${results.last}\n'
          : '';

      String failureHint = '';
      if (consecutiveFailures >= 3) {
        failureHint =
            '\n\nWARNING: You have failed $consecutiveFailures times in a row with the same approach. You MUST try a completely different action. If open_app failed, try press_home and look for the app icon on the home screen instead. If click_text failed, use click_at with coordinates. Do NOT repeat the same failed action.';
      }

      final prompt =
          '''TASK: $userGoal

CURRENT SCREEN TEXT DUMP:
$screenContent$prevResultStr$failureHint
Step ${step + 1}/${_aiService.maxSteps}. Look at the text dump and coordinates. What is the next action?''';

      developer.log('=== AI PROMPT ===\n$prompt', name: 'PrivateAgent');

      String response;
      try {
        _cancelCompleter = Completer<void>();
        final aiFuture = _aiService.sendTaskMessage(_taskSystemPrompt, prompt);

        final result = await Future.any([
          aiFuture.then((r) => r),
          _cancelCompleter!.future.then((_) => null),
        ]);

        if (result == null || _cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          await _notificationService.showTaskCompleteNotification(
            'Task Cancelled',
            'Task was stopped by the user.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Cancelled',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Task Cancelled');
          return 'Task cancelled.';
        }

        final aiResponse = result as AiResponse;
        response = aiResponse.content;
        totalTokens += aiResponse.totalTokens;

        developer.log(
          '=== RAW AI RESPONSE ===\n$response',
          name: 'PrivateAgent',
        );
      } catch (e) {
        if (_cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          await _notificationService.showTaskCompleteNotification(
            'Task Cancelled',
            'Task was stopped by the user.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Cancelled',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Task Cancelled');
          await Future.delayed(const Duration(seconds: 2));
          return 'Task cancelled.';
        }
        results.add('AI error: $e');
        _report('Error: $e');
        await _notificationService.showTaskCompleteNotification(
          'Task Error',
          'AI encountered an error.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Failed',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('AI Error: $e');
        await Future.delayed(const Duration(seconds: 3));
        return 'I could not complete the task because the AI service failed.';
      }

      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notificationService.showTaskCompleteNotification(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('Task Cancelled');
        await Future.delayed(const Duration(seconds: 2));
        return 'Task cancelled.';
      }

      Map<String, dynamic>? actionJson;
      String? parsedJsonStr;
      try {
        String jsonStr = _extractJson(response);

        actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
        parsedJsonStr = jsonStr;
      } catch (firstError) {
        developer.log(
          '=== JSON PARSE FAILED, RETRYING ===\nError: $firstError\nRaw: $response',
          name: 'PrivateAgent',
        );
        _report('Retrying step ${step + 1}...\n(Failed to parse: $firstError)');
        await Future.delayed(const Duration(seconds: 2));
        try {
          final retryResponse = await _aiService.sendTaskMessage(
            _taskSystemPrompt,
            prompt,
          );
          totalTokens += retryResponse.totalTokens;
          developer.log(
            '=== RETRY AI RESPONSE ===\n${retryResponse.content}',
            name: 'PrivateAgent',
          );

          String jsonStr = _extractJson(retryResponse.content);
          actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
          parsedJsonStr = jsonStr;
        } catch (e) {
          results.add('Step ${step + 1}: Error after retry: $e');

          String debugInfo = 'Error: $e';
          _report('AI Error: $debugInfo\n\nRaw output:\n${response}');

          await _notificationService.showTaskCompleteNotification(
            'Task Error',
            'AI formatting error.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Agent Error: $e');
          await Future.delayed(const Duration(seconds: 3));
          return 'I could not understand the AI response. Please try again.';
        }
      }

      final action = actionJson['action'] as String? ?? 'done';
      final params = actionJson['params'] as Map<String, dynamic>? ?? {};
      final reasoning = actionJson['reasoning'] as String? ?? '';
      final isComplete = actionJson['is_complete'] == true;

      developer.log(
        '=== PARSED ACTION ===\nAction: $action\nParams: $params\nReasoning: $reasoning\nIs Complete: $isComplete',
        name: 'PrivateAgent',
      );

      _report('Step ${step + 1}: $reasoning');

      sameActionCount = action == lastAction ? sameActionCount + 1 : 1;
      final repeatLimit = action == 'press_enter'
          ? 2
          : (action == 'scroll' || action == 'swipe' ? 3 : 1000);
      if (sameActionCount > repeatLimit) {
        final blockedResult =
            'Blocked repeated $action action. Use a different action on the visible screen.';
        results.add(blockedResult);
        _report(blockedResult);
        consecutiveFailures = 3;
        lastFailedAction = action;
        lastAction = action;
        continue;
      }
      lastAction = action;

      bool success = false;
      String actionResult = '';

      switch (action) {
        case 'click_text':
          final text = params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;

        case 'click_at':
          final x = (params['x'] as num?)?.toDouble() ?? 0;
          final y = (params['y'] as num?)?.toDouble() ?? 0;
          success = await _screenService.clickAt(x, y);
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;

        case 'type_text':
          final text = params['text'] as String? ?? '';
          final hint = params['field_hint'] as String?;
          success = await _screenService.typeText(text, fieldHint: hint);
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;

        case 'press_enter':
          success = await _submitKeyboardAction();
          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';
          break;

        case 'swipe':
          final startX = (params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (params['startY'] as num?)?.toDouble() ?? 2000;
          final endX = (params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (params['endY'] as num?)?.toDouble() ?? 500;

          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;

        case 'scroll':
          final direction = params['direction'] as String? ?? 'down';
          success = await _performScroll(direction);
          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';
          break;

        case 'press_back':
          success = await _screenService.pressBack();
          actionResult = 'Pressed back';
          break;

        case 'press_home':
          success = await _screenService.pressHome();
          actionResult = 'Pressed home';
          break;

        case 'open_app':
          final appName = params['app_name'] as String? ?? '';
          actionResult = await _appLauncher.openApp(appName);
          success = actionResult.startsWith('Opened');
          break;

        case 'open_package':
          final pkgName = params['package_name'] as String? ?? '';
          actionResult = await _appLauncher.openPackage(pkgName);
          success = actionResult.startsWith('Launched');
          break;

        case 'wait':
          await Future.delayed(const Duration(seconds: 1));
          actionResult = 'Waited';
          success = true;
          break;

        case 'done':
          results.add('Task complete: $reasoning');
          _report('Task complete: $reasoning');
          await _notificationService.showTaskCompleteNotification(
            'Task Completed',
            reasoning.trim().isEmpty ? 'Agent finished its goal.' : reasoning,
          );
          await _screenService.showToast('Task completed');
          return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();

        default:
          actionResult = 'Unknown action: $action';
      }

      developer.log(
        '=== NATIVE EXECUTION RESULT ===\n$actionResult',
        name: 'PrivateAgent',
      );

      if (!success) {
        if (action == lastFailedAction) {
          consecutiveFailures++;
        } else {
          consecutiveFailures = 1;
          lastFailedAction = action;
        }

        if (consecutiveFailures >= 5) {
          results.add(
            'Agent is stuck. Stopping task after $consecutiveFailures consecutive failures.',
          );
          _report('Agent stuck — stopping task.');
          await _notificationService.showTaskCompleteNotification(
            'Task Stuck',
            'Agent could not complete the task after repeated failures.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Agent stuck. Task stopped.');
          await Future.delayed(const Duration(seconds: 4));
          return 'I could not complete the task. Please try again.';
        }

        final recovery = await _recoveryEngine.diagnose(action, screenContent);
        _report('Recovering: ${recovery.description}');

        if (recovery.action == 'wait') {
          await Future.delayed(const Duration(seconds: 2));
        } else if (recovery.action == 'press_back') {
          await _screenService.pressBack();
        } else if (recovery.action == 'scroll') {
          final dir = recovery.params['direction'] ?? 'down';
          if (dir == 'down') {
            await _shizukuService.runCommand(
              'input swipe 540 1800 540 600 600',
            );
          } else {
            await _shizukuService.runCommand(
              'input swipe 540 600 540 1800 600',
            );
          }
        } else if (recovery.action == 'press_home') {
          await _screenService.pressHome();
        }

        results.add('Recovery step: ${recovery.description}');
        continue;
      } else {
        consecutiveFailures = 0;
        lastFailedAction = '';
        executedSteps.add(ActionStep(action: action, params: params));
      }

      results.add('Step ${step + 1}: $actionResult ($reasoning)');

      if (!isComplete && (step + 1) % 3 == 0) {
        await _screenService.showToast('Working... (Step ${step + 1})');
      }

      if (isComplete) {
        results.add('Task complete.');
        _report('Task complete.');
        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          'Agent finished its goal.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Success',
          totalTokens,
          step,
          results,
        );

        await _skillMemory.saveSkill(userGoal, executedSteps);

        await _screenService.showToast('Task Complete!');
        await Future.delayed(const Duration(seconds: 4));
        return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
      }
    }

    results.add(
      'Reached maximum steps (${_aiService.maxSteps}). Task may be incomplete.',
    );
    _report('Reached maximum steps.');
    await _notificationService.showTaskCompleteNotification(
      'Task Stopped',
      'Reached maximum steps (${_aiService.maxSteps}).',
    );
    await TaskHistoryLogger.logTask(
      userGoal,
      'Failed',
      totalTokens,
      _aiService.maxSteps,
      results,
    );
    await _screenService.showToast('Reached maximum steps.');
    await Future.delayed(const Duration(seconds: 4));

    return 'I could not complete the task within the allowed steps.';
  }

  void _report(String message) {
    onProgress?.call(message);
  }

  Future<bool> _submitKeyboardAction() async {
    if (await _screenService.pressEnter()) return true;

    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable) return false;

    final result = await _shizukuService.runCommand('input keyevent 66');
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  Future<bool> _performScroll(String direction) async {
    if (await _screenService.scroll(direction)) return true;

    final isDown = direction.toLowerCase() == 'down';
    return _performSwipe(540, isDown ? 1800 : 600, 540, isDown ? 600 : 1800);
  }

  Future<bool> _performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) return true;

    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable) return false;

    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} '
      '${endX.toInt()} ${endY.toInt()} 600',
    );
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  Future<bool> _replaySkill(SavedSkill skill, List<String> results) async {
    for (int i = 0; i < skill.steps.length; i++) {
      if (_cancelled) return false;

      final step = skill.steps[i];
      _report('Replaying step ${i + 1}/${skill.steps.length}: ${step.action}');

      int delay = 1200;
      if (step.action == 'open_app' || step.action == 'open_package')
        delay = 3000;
      else if (step.action == 'type_text')
        delay = 2000;
      else if (step.action == 'click_text' || step.action == 'click_at')
        delay = 1500;
      else if (step.action == 'scroll')
        delay = 1000;

      await Future.delayed(Duration(milliseconds: delay));

      bool success = false;
      String actionResult = '';

      switch (step.action) {
        case 'click_text':
          final text = step.params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;
        case 'click_at':
          final x = (step.params['x'] as num?)?.toDouble() ?? 0;
          final y = (step.params['y'] as num?)?.toDouble() ?? 0;
          success = await _screenService.clickAt(x, y);
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;
        case 'type_text':
          final text = step.params['text'] as String? ?? '';
          final hint = step.params['field_hint'] as String?;
          success = await _screenService.typeText(text, fieldHint: hint);
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;
        case 'press_enter':
          success = await _submitKeyboardAction();
          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';
          break;
        case 'swipe':
          final startX = (step.params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (step.params['startY'] as num?)?.toDouble() ?? 2000;
          final endX = (step.params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (step.params['endY'] as num?)?.toDouble() ?? 500;
          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;
        case 'scroll':
          final direction = step.params['direction'] as String? ?? 'down';
          success = await _performScroll(direction);
          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';
          break;
        case 'press_back':
          success = await _screenService.pressBack();
          actionResult = 'Pressed back';
          break;
        case 'press_home':
          success = await _screenService.pressHome();
          actionResult = 'Pressed home';
          break;
        case 'open_app':
          final appName = step.params['app_name'] as String? ?? '';
          actionResult = await _appLauncher.openApp(appName);
          success = actionResult.startsWith('Opened');
          break;
        case 'open_package':
          final pkgName = step.params['package_name'] as String? ?? '';
          actionResult = await _appLauncher.openPackage(pkgName);
          success = actionResult.startsWith('Launched');
          break;
        case 'wait':
          await Future.delayed(const Duration(seconds: 1));
          actionResult = 'Waited';
          success = true;
          break;
        case 'done':
          success = true;
          actionResult = 'Done step reached';
          break;
        default:
          success = false;
          actionResult = 'Unknown action: ${step.action}';
      }

      results.add('Memory Replay Step ${i + 1}: $actionResult');
      developer.log(
        '=== MEMORY REPLAY RESULT ===\n$actionResult',
        name: 'PrivateAgent',
      );

      if (!success) {
        return false;
      }
    }

    return true;
  }

  List<ActionStep>? _getNavigationShortcut(String goal) {
    final lower = goal.toLowerCase();

    if (lower.contains('dark mode') || lower.contains('dark theme')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Display'}),
      ];
    }
    if (lower.contains('wifi') || lower.contains('wi-fi')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(
          action: 'click_text',
          params: {'text': 'Network & internet'},
        ),
      ];
    }
    if (lower.contains('bluetooth')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Connected devices'}),
      ];
    }

    final appPatterns = <String, List<String>>{
      'Settings': ['settings', 'brightness', 'display', 'notification'],
      'Play Store': [
        'play store',
        'playstore',
        'download',
        'install app',
        'google play',
      ],
      'YouTube': ['youtube'],
      'WhatsApp': ['whatsapp'],
      'Chrome': ['chrome', 'browse', 'search google'],
      'Camera': ['camera', 'take a photo', 'take photo', 'take a picture'],
      'Gallery': ['gallery', 'photos'],
      'Messages': ['message', 'sms', 'text to'],
      'Phone': ['call', 'dial'],
      'Gmail': ['gmail', 'email'],
      'Maps': ['maps', 'navigate to', 'directions'],
      'Clock': ['alarm', 'timer', 'stopwatch'],
      'Calculator': ['calculator', 'calculate', 'calc'],
    };

    for (final entry in appPatterns.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return [
            ActionStep(action: 'open_app', params: {'app_name': entry.key}),
          ];
        }
      }
    }

    final openMatch = RegExp(r'^open\s+([a-zA-Z0-9]+)').firstMatch(lower);
    if (openMatch != null) {
      String app = openMatch.group(1)!;
      app = app[0].toUpperCase() + app.substring(1);
      return [
        ActionStep(action: 'open_app', params: {'app_name': app}),
      ];
    }

    return null;
  }
}
