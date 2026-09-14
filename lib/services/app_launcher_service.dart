import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppLauncherService {
  List<AppInfo>? _cachedApps;

  /// Get all installed apps (cached), including system apps!
  Future<List<AppInfo>> getInstalledApps() async {
    _cachedApps ??= await InstalledApps.getInstalledApps(false, false);
    return _cachedApps!;
  }

  /// Clear app cache
  void clearCache() {
    _cachedApps = null;
  }

  /// Find apps matching a query
  Future<List<AppInfo>> searchApps(String query) async {
    final apps = await getInstalledApps();
    final lowerQuery = query.toLowerCase();
    return apps.where((app) {
      return app.name.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Find an app by package name (fast, exact)
  Future<AppInfo?> findByPackage(String packageName) async {
    final apps = await getInstalledApps();
    try {
      return apps.firstWhere(
        (app) => app.packageName.toLowerCase() == packageName.toLowerCase(),
      );
    } catch (e) {
      return null;
    }
  }

  /// SMART OPEN: Try package name first (fast), then fall back to name search
  Future<String> smartOpenApp(String query) async {
    // Step 1: Agar query mein dot (.) hai toh package name hai
    if (query.contains('.')) {
      final result = await openPackage(query);
      if (!result.startsWith('Error')) {
        return result;
      }
    }

    // Step 2: Naam se dhoondein
    return await openApp(query);
  }

  /// Open an app by name (STRICT match - no wrong app)
  Future<String> openApp(String appName) async {
    final matches = await searchApps(appName);

    if (matches.isEmpty) {
      return 'Could not find app "$appName". Try being more specific.';
    }

    // Exact match dhoondein pehle
    final exactMatches = matches.where(
      (app) => app.name.toLowerCase() == appName.toLowerCase(),
    ).toList();

    if (exactMatches.length == 1) {
      try {
        await InstalledApps.startApp(exactMatches.first.packageName);
        return 'Opened ${exactMatches.first.name}';
      } catch (e) {
        return 'Error opening ${exactMatches.first.name}: $e';
      }
    }

    // Agar multiple matches hain toh user se poochein (WRONG APP NA KHOLE)
    if (matches.length > 1) {
      final names = matches
          .take(5)
          .map((e) => '${e.name} (${e.packageName})')
          .join(', ');
      return 'Multiple apps found: $names. Please specify the exact name or package name to open.';
    }

    // Sirf ek match hai
    try {
      await InstalledApps.startApp(matches.first.packageName);
      return 'Opened ${matches.first.name}';
    } catch (e) {
      return 'Error opening ${matches.first.name}: $e';
    }
  }

  /// Open an app by exact package name (FASTEST)
  Future<String> openPackage(String packageName) async {
    try {
      await InstalledApps.startApp(packageName);
      return 'Launched $packageName';
    } catch (e) {
      return 'Error launching $packageName: $e';
    }
  }

  /// Open a URL
  Future<String> openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return 'Opened $url';
      }
      return 'Cannot open $url';
    } catch (e) {
      return 'Error opening URL: $e';
    }
  }
}
