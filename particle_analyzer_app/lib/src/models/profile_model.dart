class GrindProfile {
  final String id;
  final String name;
  final String grinder;
  final String grindSetting;
  final DateTime timestamp;
  
  // Summary stats (e.g. mean_um, Dv50_um, etc.)
  final Map<String, double> statistics;
  
  // Detection slider parameters used
  final Map<String, dynamic> parameters;
  
  // Equivalent diameters of all detected particles to rebuild histogram
  final List<double> equivDiameters;
  
  // Persistent copied image paths
  final String localAnnotatedImagePath;
  final String localBinaryMaskPath;
  final String? localSquareDetectionPath;

  GrindProfile({
    required this.id,
    required this.name,
    required this.grinder,
    required this.grindSetting,
    required this.timestamp,
    required this.statistics,
    required this.parameters,
    required this.equivDiameters,
    required this.localAnnotatedImagePath,
    required this.localBinaryMaskPath,
    this.localSquareDetectionPath,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'grinder': grinder,
      'grindSetting': grindSetting,
      'timestamp': timestamp.toIso8601String(),
      'statistics': statistics,
      'parameters': parameters,
      'equivDiameters': equivDiameters,
      'localAnnotatedImagePath': localAnnotatedImagePath,
      'localBinaryMaskPath': localBinaryMaskPath,
      if (localSquareDetectionPath != null)
        'localSquareDetectionPath': localSquareDetectionPath,
    };
  }

  factory GrindProfile.fromJson(Map<String, dynamic> json) {
    return GrindProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      grinder: json['grinder'] as String? ?? '',
      grindSetting: json['grindSetting'] as String? ?? '',
      timestamp: DateTime.parse(json['timestamp'] as String),
      statistics: (json['statistics'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
      parameters: json['parameters'] as Map<String, dynamic>,
      equivDiameters: (json['equivDiameters'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      localAnnotatedImagePath: json['localAnnotatedImagePath'] as String,
      localBinaryMaskPath: json['localBinaryMaskPath'] as String,
      localSquareDetectionPath: json['localSquareDetectionPath'] as String?,
    );
  }

  GrindProfile copyWith({
    String? name,
    String? grinder,
    String? grindSetting,
  }) {
    return GrindProfile(
      id: id,
      name: name ?? this.name,
      grinder: grinder ?? this.grinder,
      grindSetting: grindSetting ?? this.grindSetting,
      timestamp: timestamp,
      statistics: statistics,
      parameters: parameters,
      equivDiameters: equivDiameters,
      localAnnotatedImagePath: localAnnotatedImagePath,
      localBinaryMaskPath: localBinaryMaskPath,
      localSquareDetectionPath: localSquareDetectionPath,
    );
  }
}
