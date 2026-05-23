class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.storageBaseUrl,
  });

  final String apiBaseUrl;
  final String wsBaseUrl;
  final String storageBaseUrl;

  static AppConfig fromEnv() {
    const apiBaseUrl = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:30001',
    );
    const wsBaseUrl = String.fromEnvironment(
      'WS_BASE_URL',
      defaultValue: 'ws://localhost:30001',
    );
    const storageBaseUrl = String.fromEnvironment(
      'STORAGE_BASE_URL',
      defaultValue: 'http://localhost:30001',
    );
    return const AppConfig(
      apiBaseUrl: apiBaseUrl,
      wsBaseUrl: wsBaseUrl,
      storageBaseUrl: storageBaseUrl,
    );
  }
}
