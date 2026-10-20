enum AudioSource {
  asmrOne('ASMR.ONE'),
  jpAsmr('JP-ASMR');

  const AudioSource(this.label);

  final String label;

  static AudioSource fromValue(String? value) => AudioSource.values.firstWhere(
    (source) => source.name == value,
    orElse: () => AudioSource.asmrOne,
  );
}
