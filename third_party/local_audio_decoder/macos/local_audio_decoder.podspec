Pod::Spec.new do |s|
  s.name             = 'local_audio_decoder'
  s.version          = '0.1.0'
  s.summary          = 'Local MP3, WAV and FLAC decoding for subtitle generation.'
  s.description      = 'A bounded, local PCM decoder backed by miniaudio.'
  s.homepage         = 'https://github.com/Shiniester/KikoFlu'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'KikoFlu' => 'https://github.com/Shiniester/KikoFlu' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
