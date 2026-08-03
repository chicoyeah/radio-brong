import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/services.dart'; // Import for Clipboard
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'checkpoint_storage.dart';
import 'update_checker.dart';
import 'youtube_playlist_utils.dart';

late MyAudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _audioHandler = await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.mycompany.myapp.channel.audio',
      androidNotificationChannelName: 'Radio Brong',
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );
  // Request notification permission for Android 13+
  await Permission.notification.request();
  runApp(const RadioBrongApp());
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = ja.AudioPlayer();
  void Function(String)? onNotificationAction;

  MyAudioHandler() {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: AudioProcessingState.ready,
      playing: false,
    ));
  }

  @override
  Future<void> play() async {
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.pause,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
    ));
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
    ));
  }

  @override
  Future<void> stop() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.ready,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
    ));
    onNotificationAction?.call('stop');
  }

  Future<void> stopSilently() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.ready,
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    onNotificationAction?.call('seek:${position.inSeconds}');
  }

  @override
  Future<void> skipToNext() async {
    onNotificationAction?.call('next');
  }

  @override
  Future<void> skipToPrevious() async {
    onNotificationAction?.call('previous');
  }

  void updateMetadata(TrackItem item) {
    mediaItem.add(MediaItem(
      id: item.videoId,
      album: "Radio Brong",
      title: item.title,
      artist: item.participant,
      duration: item.duration,
      artUri: item.thumbnailUrl != null ? Uri.parse(item.thumbnailUrl!) : null,
    ));
  }

  void updatePosition(Duration position) {
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }
}

class RadioBrongApp extends StatelessWidget {
  const RadioBrongApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radio Brong',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.red,
        scaffoldBackgroundColor: const Color(0xFF1E1E2F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF4C4C),
          secondary: Color(0xFF00FFFF),
          surface: Color(0xFF1E1E2F),
        ),
      ),
      home: const RadioBrongHome(),
    );
  }
}

class RadioBrongHome extends StatefulWidget {
  const RadioBrongHome({super.key});

  @override
  State<RadioBrongHome> createState() => _RadioBrongHomeState();
}

class _RadioBrongHomeState extends State<RadioBrongHome> {
  late final String _selectedLogo;

  static const String _introPlaylistUrl = 'https://www.youtube.com/playlist?list=PLBr8N5C2sDZI';

  late final WebViewController _webViewController;
  final YoutubeExplode _yt = YoutubeExplode();
  bool _autoRedirectAttempted = false;
  
  List<String> _lastParticipants = [];
  List<PlaylistItem> _playlist = [];
  List<TrackItem> _tracks = [];
  int _currentIndex = -1;
  bool _isProcessing = false;
  bool _isTransitioning = false;
  DateTime? _lastTrackChange;
  Timer? _videoStateTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isOffline = false;
  double _volumeBoost = 1.0;
  final CheckpointStorage _checkpointStorage = CheckpointStorage();
  CheckpointData? _checkpoint;
  bool _hasCheckpoint = false;

  @override
  void initState() {
    super.initState();
    _initLogo();
    _initWebView();
    _listenToMediaButtons();
    _startVideoStatePolling();
    _setupConnectivityListener();
    _loadCheckpoint();
    _checkForAppUpdate();
  }

  void _initLogo() {
    if (Random().nextDouble() < 0.002) {
      _selectedLogo = 'assets/RedioBrung.gif';
    } else {
      final now = DateTime.now();
      if (now.month == 12) {
        _selectedLogo = 'assets/Brongmas.png';
      } else if (now.month == 10) {
        _selectedLogo = 'assets/Brongween.png';
      } else if (now.month == 4 && now.day == 25) {
        _selectedLogo = 'assets/Forzabrong.png';
      } else if (now.month == 4 && now.day == 1) {
        _selectedLogo = 'assets/Brongfools.gif';
      } else if (now.month == 1 && now.day == 1) {
        _selectedLogo = 'assets/Bronganno.png';
      } else if (now.month == 2 && now.day == 14) {
        _selectedLogo = 'assets/Brongvalentino.png';
      } else if (now.month == 2 && now.day == 29) {
        _selectedLogo = 'assets/Brong29.png';
      } else {
        _selectedLogo = 'assets/BrongLogo.gif';
      }
    }
  }

  bool get _isChristmas => _selectedLogo == 'assets/Brongmas.png';
  bool get _isValentine => _selectedLogo == 'assets/Brongvalentino.png';
  bool get _isHalloween => _selectedLogo == 'assets/Brongween.png';

  Color get _seasonalPrimaryColor {
    if (_isChristmas) return const Color(0xFFB71C1C);
    if (_isValentine) return const Color(0xFFD81B60);
    if (_isHalloween) return const Color(0xFFFF9800);
    return const Color(0xFFFF4C4C);
  }

  Color get _seasonalSecondaryColor {
    if (_isChristmas) return const Color(0xFF43A047);
    if (_isValentine) return const Color(0xFFFF80AB);
    if (_isHalloween) return const Color(0xFF6A1B9A);
    return const Color(0xFF00FFFF);
  }

  Color get _seasonalSurfaceColor {
    if (_isChristmas) return const Color(0xFF0D170F);
    if (_isValentine) return const Color(0xFF2F0B1B);
    if (_isHalloween) return const Color(0xFF1A0F07);
    return const Color(0xFF1E1E2F);
  }

  Color get _seasonalBackgroundColor {
    if (_isChristmas) return const Color(0xFF09130B);
    if (_isValentine) return const Color(0xFF19080F);
    if (_isHalloween) return const Color(0xFF130C08);
    return const Color(0xFF1E1E2F);
  }

  Color get _seasonalButtonColor {
    if (_isChristmas) return const Color(0xFF00897B);
    if (_isValentine) return const Color(0xFFD81B60);
    if (_isHalloween) return const Color(0xFFFF6D00);
    return const Color(0xFFFF4C4C);
  }

  ThemeData get _seasonalThemeData {
    final defaultDark = ThemeData.dark();
    return defaultDark.copyWith(
      scaffoldBackgroundColor: _seasonalBackgroundColor,
      colorScheme: defaultDark.colorScheme.copyWith(
        primary: _seasonalPrimaryColor,
        secondary: _seasonalSecondaryColor,
        surface: _seasonalSurfaceColor,
      ),
    );
  }

  void _initWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'FlutterRadio',
        onMessageReceived: (JavaScriptMessage message) {
          if (message.message == 'videoEnded') {
            debugPrint("Video ended via JS channel");
            _nextTrack();
          } else if (message.message == 'videoPlaying') {
            if (!_isTransitioning) _audioHandler.play();
          } else if (message.message == 'videoPaused') {
            if (!_isTransitioning) _audioHandler.pause();
          } else if (message.message == 'unavailableDetected' || message.message == 'unavailableDetectedNoLink') {
            debugPrint("Video unavailable detected: ${message.message}");
            _handleUnavailableVideo();
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            debugPrint('Page finished loading: $url');
            setState(() {
              _isTransitioning = false;
            });
            _webViewController.runJavaScript("""
              (function() {
                function setupVideo() {
                  var v = document.querySelector('video');
                  if (v) {
                    if (v.muted) v.muted = false;
                    if (v.volume === 0) v.volume = 1.0;
                    
                    if (!v._radioSetup) {
                      v._radioSetup = true;
                      v.loop = false;
                      v._retryCount = 0;
                      v._retryTimer = null;

                      function attemptPlaybackRetry() {
                        if (v._retryCount >= 3) {
                          console.log('Max playback retries reached');
                          return;
                        }

                        v._retryCount += 1;
                        if (v._retryTimer) {
                          clearTimeout(v._retryTimer);
                        }

                        v._retryTimer = setTimeout(function() {
                          try {
                            v.load();
                            v.play().catch(function(playErr) {
                              console.log('Retry play failed:', playErr);
                            });
                          } catch (e) {
                            console.log('Retry attempt failed:', e);
                          }
                        }, 2000);
                      }
                      
                      v.addEventListener('ended', function() {
                        console.log('Video ended event fired');
                        FlutterRadio.postMessage('videoEnded');
                      });

                      v.addEventListener('play', function() {
                        v._retryCount = 0;
                        FlutterRadio.postMessage('videoPlaying');
                      });

                      v.addEventListener('pause', function() {
                        FlutterRadio.postMessage('videoPaused');
                      });

                      v.addEventListener('error', function() {
                        console.log('Video playback error detected');
                        attemptPlaybackRetry();
                      });

                      v.addEventListener('timeupdate', function() {
                        if (v.duration > 1 && v.currentTime > 0 && v.currentTime >= v.duration - 0.3) {
                          if (!v._endedSent) {
                            v._endedSent = true;
                            console.log('Video near end detected');
                            FlutterRadio.postMessage('videoEnded');
                          }
                        }
                      });

                      if (!v._radioBoosterSetup) {
                        v._radioBoosterSetup = true;
                        try {
                          const AudioContextClass = window.AudioContext || window.webkitAudioContext;
                          const audioCtx = new AudioContextClass();
                          const source = audioCtx.createMediaElementSource(v);
                          const gainNode = audioCtx.createGain();
                          source.connect(gainNode);
                          gainNode.connect(audioCtx.destination);
                          gainNode.gain.value = 1.0;
                          window._radioVolumeBooster = gainNode;
                          audioCtx.resume().catch(() => {});
                        } catch (e) {
                          console.log('Audio booster not available', e);
                        }
                      }

                      // Auto-play if we are supposed to be playing
                      v.play().catch(e => {
                        console.log('Initial play failed:', e);
                      });
                    }
                  }

                  var err = document.querySelector('.ytp-error, .ytp-error-content, .ytp-error-message-container, .yt-playability-error-supported-renderers');
                  var btn = document.querySelector('.ytp-error-button, .ytp-button.ytp-error-button, .ytp-error-content-link, .ytp-impression-link');
                  
                  var errVisible = err && (err.offsetHeight > 0 || err.getClientRects().length > 0);
                  var btnVisible = btn && (btn.offsetHeight > 0 || btn.getClientRects().length > 0);
                  
                  var txt = (err ? err.innerText.toLowerCase() : "") + (btn ? btn.innerText.toLowerCase() : "");
                  var hasErrTxt = txt.includes('unavailable') || 
                                  txt.includes('disponibile') || 
                                  txt.includes('non disponibile') || 
                                  txt.includes('watch on youtube') ||
                                  txt.includes('guarda su youtube') ||
                                  txt.includes('disabilitata') ||
                                  txt.includes('non è disponibile');

                  if ((errVisible && hasErrTxt) || (btnVisible && hasErrTxt)) {
                    console.log('Unavailable video detected');
                    FlutterRadio.postMessage('unavailableDetected');
                  }
                }
                setupVideo();
                var observer = new MutationObserver(setupVideo);
                observer.observe(document.body, { childList: true, subtree: true });
              })();
            """);
          },
        ),
      );

    if (_webViewController.platform is AndroidWebViewController) {
      (_webViewController.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  void _listenToMediaButtons() {
    bool? lastState;
    _audioHandler.playbackState.listen((state) {
      if (lastState == state.playing) return;
      lastState = state.playing;
      
      if (state.playing) {
        _webViewController.runJavaScript("document.querySelector('video')?.play()");
      } else {
        _webViewController.runJavaScript("document.querySelector('video')?.pause()");
      }
    });

    _audioHandler.onNotificationAction = (String action) {
      if (action == 'next') _nextTrack();
      if (action == 'previous') _prevTrack();
      if (action == 'stop') _internalStop();
      if (action.startsWith('seek:')) {
        final seconds = int.tryParse(action.split(':')[1]);
        if (seconds != null) {
          _webViewController.runJavaScript("document.querySelector('video').currentTime = $seconds");
        }
      }
    };
  }

  void _setupConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final bool isConnected = results.any((result) => result != ConnectivityResult.none);
      if (isConnected && _isOffline) {
        _reloadIfNecessary();
      }
      setState(() {
        _isOffline = !isConnected;
      });
    });
  }

  void _reloadIfNecessary() {
    if (_currentIndex != -1) {
      _webViewController.reload();
    }
  }

  @override
  void dispose() {
    _yt.close();
    _videoStateTimer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void _startVideoStatePolling() {
    _videoStateTimer?.cancel();
    _videoStateTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (_currentIndex == -1 || _isProcessing || _isTransitioning) return;
      try {
        final result = await _webViewController.runJavaScriptReturningResult(
          "var v = document.querySelector('video'); v ? (v.ended || (v.duration > 1 && v.currentTime > 0 && v.currentTime >= v.duration - 0.5)) + ',' + v.currentTime : 'false,0'"
        );
        
        final parts = result.toString().replaceAll('"', '').split(',');
        if (parts.length >= 2) {
          final bool ended = parts[0] == 'true';
          final double currentTime = double.tryParse(parts[1]) ?? 0;
          
          if (ended) {
            debugPrint("Video ended detected via polling");
            _nextTrack();
          } else {
            _audioHandler.updatePosition(Duration(seconds: currentTime.toInt()));
          }
        }
      } catch (e) {}
    });
  }

  Future<void> _loadCheckpoint() async {
    final checkpoint = await _checkpointStorage.loadCheckpoint();
    if (!mounted) return;
    setState(() {
      _checkpoint = checkpoint;
      _hasCheckpoint = checkpoint != null;
    });
  }

  Future<void> _checkForAppUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final updateInfo = await UpdateChecker.checkForUpdate(
        currentVersion: packageInfo.version,
      );

      if (!mounted || updateInfo == null) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Aggiornamento disponibile'),
            content: Text(
              'È disponibile la versione ${updateInfo.version}. Vuoi aprire la pagina delle release di Radio Brong?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('No'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  final uri = Uri.parse(updateInfo.url);
                  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Impossibile aprire il link delle release.')),
                    );
                  }
                },
                child: const Text('Sì'),
              ),
            ],
          ),
        );
      });
    } catch (_) {}
  }

  Future<void> _saveCheckpoint() async {
    if (_currentIndex < 0 || _tracks.isEmpty) {
      await _checkpointStorage.clearCheckpoint();
      if (mounted) {
        setState(() {
          _checkpoint = null;
          _hasCheckpoint = false;
        });
      }
      return;
    }

    final checkpointTracks = _tracks
        .sublist(_currentIndex)
        .map((track) => CheckpointTrack(
              participant: track.participant,
              videoId: track.videoId,
              title: track.title,
              thumbnailUrl: track.thumbnailUrl,
              durationSeconds: track.duration?.inSeconds,
            ))
        .toList();

    await _checkpointStorage.saveCheckpoint(
      checkpointTracks,
      0,
    );
    if (mounted) {
      setState(() {
        _checkpoint = CheckpointData(currentIndex: 0, tracks: checkpointTracks);
        _hasCheckpoint = checkpointTracks.isNotEmpty;
      });
    }
  }

  Future<void> _resumeFromCheckpoint() async {
    final checkpoint = _checkpoint;
    if (checkpoint == null || checkpoint.tracks.isEmpty) return;

    setState(() {
      _tracks = checkpoint.tracks
          .map((track) => TrackItem(
                participant: track.participant,
                videoId: track.videoId,
                title: track.title,
                thumbnailUrl: track.thumbnailUrl,
                duration: track.durationSeconds != null ? Duration(seconds: track.durationSeconds!) : null,
              ))
          .toList();
      _playlist = [];
      _currentIndex = 0;
      _isProcessing = false;
      _isTransitioning = true;
      _autoRedirectAttempted = false;
      _volumeBoost = 1.0;
      _hasCheckpoint = false;
    });
    await _checkpointStorage.clearCheckpoint();
    if (mounted) {
      setState(() {
        _checkpoint = null;
      });
    }
    _playCurrent();
  }

  Future<void> _openParticipantSelector() async {
    if (_isProcessing) return;
    final themeData = _seasonalThemeData;
    final List<String>? result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (context) => ParticipantSelectorPage(initialList: _lastParticipants, themeData: themeData),
        fullscreenDialog: true,
      ),
    );
    if (result != null && result.isNotEmpty) {
      _lastParticipants = List.from(result);
      List<String> shuffled = List.from(result)..shuffle();
      await _collectSongs(shuffled);
    }
  }

  Future<String?> _pickRandomIntroUrl() async {
    try {
      final playlistId = extractPlaylistIdFromUrl(_introPlaylistUrl);
      if (playlistId == null) {
        throw Exception('Playlist ID non trovata');
      }

      final response = await http.get(Uri.parse('https://www.youtube.com/playlist?list=$playlistId'));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final videoIds = extractVideoIdsFromPlaylistHtml(response.body);
      if (videoIds.isNotEmpty) {
        final selectedId = videoIds[Random().nextInt(videoIds.length)];
        return 'https://www.youtube.com/watch?v=$selectedId';
      }
    } catch (e) {
      debugPrint('Impossibile caricare la playlist intro: $e');
    }

    return null;
  }

  Future<void> _collectSongs(List<String> participants) async {
    List<PlaylistItem> newPlaylist = [];
    final introUrl = await _pickRandomIntroUrl();
    if (introUrl != null) {
      newPlaylist.add(PlaylistItem(participant: "Intro", url: introUrl));
    }

    final themeData = _seasonalThemeData;
    for (String p in participants) {
      final PlaylistItem? item = await Navigator.of(context).push<PlaylistItem>(
        MaterialPageRoute(
          builder: (context) => YoutubeSearchPage(participantName: p, themeData: themeData),
          fullscreenDialog: true,
        ),
      );
      if (item != null) {
        newPlaylist.add(item);
      }
    }

    if (newPlaylist.isNotEmpty) {
      await _checkpointStorage.clearCheckpoint();
      if (mounted) {
        setState(() {
          _playlist = newPlaylist;
          _checkpoint = null;
          _hasCheckpoint = false;
        });
      }
      _startProcessing();
    }
  }

  Future<void> _startProcessing() async {
    setState(() {
      _tracks = [];
      _currentIndex = -1;
      _isProcessing = true;
    });
    for (int i = 0; i < _playlist.length; i++) {
      await _processItem(i);
    }
    if (mounted) {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _processItem(int index) async {
    PlaylistItem item = _playlist[index];
    try {
      var video = await _yt.videos.get(item.url);
      if (mounted) {
        setState(() {
          _tracks.add(TrackItem(
            participant: item.participant,
            videoId: video.id.value,
            title: video.title,
            thumbnailUrl: video.thumbnails.mediumResUrl,
            duration: video.duration,
          ));
          if (index == 0) {
            _currentIndex = 0;
            _playCurrent();
          }
        });
      }
    } catch (e) {
      debugPrint("Metadata error: $e");
    }
  }

  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _tracks.length) return;
    setState(() {
      _isTransitioning = true;
      _autoRedirectAttempted = false;
      _volumeBoost = 1.0;
    });
    TrackItem item = _tracks[_currentIndex];
    
    _audioHandler.updateMetadata(item);
    _audioHandler.updatePosition(Duration.zero);
    _audioHandler.play();

    await _saveCheckpoint();

    final url = 'https://www.yout-ube.com/watch?v=${item.videoId}';
    await _webViewController.loadRequest(Uri.parse(url));
  }

  void _handleUnavailableVideo() {
    if (_autoRedirectAttempted || _currentIndex == -1) return;
    _autoRedirectAttempted = true;
    TrackItem item = _tracks[_currentIndex];
    final youtubeUrl = 'https://www.youtube.com/watch?v=${item.videoId}';
    _webViewController.loadRequest(Uri.parse(youtubeUrl));
  }

  void _setVolumeBoost(double boost) {
    setState(() {
      _volumeBoost = boost;
    });
    _webViewController.runJavaScript("window._radioVolumeBooster && (window._radioVolumeBooster.gain.value = $boost)");
  }

  Future<void> _openVolumeBoosterSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: _seasonalSurfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        double localBoost = _volumeBoost;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Volume Booster',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _seasonalSecondaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Aumenta il volume manualmente per il brano corrente.',
                    style: TextStyle(color: Colors.white.withOpacity(0.8)),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Boost: x${localBoost.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white)),
                      TextButton(
                        onPressed: () {
                          setSheetState(() => localBoost = 1.0);
                          _setVolumeBoost(1.0);
                        },
                        child: const Text('Reset', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                  Slider(
                    value: localBoost,
                    min: 1.0,
                    max: 8.0,
                    divisions: 28,
                    label: 'x${localBoost.toStringAsFixed(2)}',
                    activeColor: _seasonalButtonColor,
                    inactiveColor: _seasonalButtonColor.withOpacity(0.4),
                    onChanged: (value) {
                      setSheetState(() => localBoost = value);
                      _setVolumeBoost(value);
                    },
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: _seasonalButtonColor),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: const Text('Chiudi', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildControlButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return Expanded(
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Center(
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }

  void _internalStop() {
    _webViewController.loadRequest(Uri.parse('about:blank'));
    _saveCheckpoint();
    setState(() {
      _currentIndex = -1;
      _tracks = [];
      _playlist = [];
    });
  }

  Future<void> _stopAudio() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Interrompi Radio"),
        content: const Text("Vuoi davvero interrompere la radio e cancellare la playlist attuale?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("No")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Sì")),
        ],
      ),
    );
    if (confirm == true) {
      _internalStop();
      _audioHandler.stopSilently();
    }
  }

  Future<void> _nextTrack() async {
    final now = DateTime.now();
    if (_lastTrackChange != null && now.difference(_lastTrackChange!) < const Duration(seconds: 2)) {
      return;
    }
    _lastTrackChange = now;

    if (_currentIndex + 1 < _tracks.length) {
      setState(() {
        _currentIndex++;
      });
      await _playCurrent();
    } else if (!_isProcessing) {
      await _checkpointStorage.clearCheckpoint();
      if (mounted) {
        setState(() {
          _currentIndex = -1;
          _checkpoint = null;
          _hasCheckpoint = false;
        });
      }
      _audioHandler.stopSilently();
      _openParticipantSelector();
    }
  }

  Future<void> _persistCurrentCheckpoint() async {
    await _saveCheckpoint();
  }

  void _prevTrack() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
      _playCurrent();
    }
  }

  @override
  Widget build(BuildContext context) {
    TrackItem? currentItem = (_currentIndex >= 0 && _currentIndex < _tracks.length) 
        ? _tracks[_currentIndex] 
        : null;

    final themeData = Theme.of(context).copyWith(
      scaffoldBackgroundColor: _seasonalBackgroundColor,
      colorScheme: Theme.of(context).colorScheme.copyWith(
        primary: _seasonalPrimaryColor,
        secondary: _seasonalSecondaryColor,
        surface: _seasonalSurfaceColor,
      ),
    );

    return Theme(
      data: themeData,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 88,
          title: Image.asset(_selectedLogo, height: 84, fit: BoxFit.contain),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            if (_currentIndex != -1)
              IconButton(
                onPressed: _openVolumeBoosterSheet,
                icon: Icon(Icons.volume_up, color: Colors.white),
                tooltip: 'Booster',
              ),
            IconButton(
              onPressed: _isProcessing ? null : _openParticipantSelector,
              icon: Icon(Icons.playlist_play, color: Colors.white),
              tooltip: 'Seleziona partecipanti',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _seasonalSurfaceColor,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_currentIndex != -1)
                          WebViewWidget(controller: _webViewController)
                        else
                          Container(
                            color: _seasonalSurfaceColor,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.radio, size: 96, color: Colors.white.withOpacity(0.18)),
                                  const SizedBox(height: 12),
                                  Text(
                                    "Nessun brano in riproduzione",
                                    style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 16),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    "Premi il pulsante qui sotto per iniziare",
                                    style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13),
                                  ),
                                  const SizedBox(height: 20),
                                  Column(
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: _isProcessing ? null : _openParticipantSelector,
                                        icon: Icon(Icons.playlist_play, color: Colors.white),
                                        label: const Text('Avvia playlist', style: TextStyle(color: Colors.white)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _seasonalButtonColor,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                        ),
                                      ),
                                      if (_hasCheckpoint) ...[
                                        const SizedBox(height: 12),
                                        OutlinedButton.icon(
                                          onPressed: _resumeFromCheckpoint,
                                          icon: const Icon(Icons.restart_alt, color: Colors.white),
                                          label: const Text('Riprendi dal checkpoint', style: TextStyle(color: Colors.white)),
                                          style: OutlinedButton.styleFrom(
                                            side: BorderSide(color: _seasonalButtonColor),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if ((currentItem?.participant ?? '').trim().isNotEmpty)
                          Positioned(
                            top: 16,
                            left: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.35),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.white.withOpacity(0.08)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.person, color: Colors.white.withOpacity(0.9), size: 16),
                                  const SizedBox(width: 8),
                                  Text(
                                    currentItem!.participant,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                                  ),
                                  if (_volumeBoost > 1.0) ...[
                                    const SizedBox(width: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _seasonalButtonColor.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        'x${_volumeBoost.toStringAsFixed(2)}',
                                        style: TextStyle(color: Colors.white.withOpacity(0.95), fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        if (_isOffline)
                          Positioned(
                            top: 16,
                            left: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withOpacity(0.88),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Text(
                                'Offline',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildControlButton(Icons.skip_previous, 'Precedente', _prevTrack),
                  const SizedBox(width: 10),
                  _buildControlButton(Icons.stop, 'Stop', _stopAudio),
                  const SizedBox(width: 10),
                  _buildControlButton(Icons.skip_next, 'Successivo', _nextTrack),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
    ),
    );
  }
}

class PlaylistItem {
  final String participant;
  final String url;
  final String? thumbnailUrl;
  PlaylistItem({required this.participant, required this.url, this.thumbnailUrl});
}

class TrackItem {
  final String participant;
  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final Duration? duration;
  TrackItem({required this.participant, required this.videoId, required this.title, this.thumbnailUrl, this.duration});
}

class ParticipantSelectorPage extends StatefulWidget {
  final List<String> initialList;
  final ThemeData themeData;
  const ParticipantSelectorPage({super.key, required this.initialList, required this.themeData});
  @override
  State<ParticipantSelectorPage> createState() => _ParticipantSelectorPageState();
}

class _ParticipantSelectorPageState extends State<ParticipantSelectorPage> {
  late List<String> _participants;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _participants = List.from(widget.initialList);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.themeData.colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        centerTitle: true,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text('Seleziona partecipanti', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Aggiungi nomi e avvia la radio', style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Annulla', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: _participants.isEmpty
                          ? Center(
                              child: Text(
                                'Nessun partecipante aggiunto ancora.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white.withOpacity(0.7)),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _participants.length,
                              separatorBuilder: (context, index) => const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                return Material(
                                  color: colorScheme.surface,
                                  borderRadius: BorderRadius.circular(18),
                                  child: ListTile(
                                    title: Text(_participants[index], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.white70),
                                      onPressed: () => setState(() => _participants.removeAt(index)),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Nome partecipante',
                                hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) => _addParticipant(),
                            ),
                          ),
                          IconButton(
                            onPressed: _addParticipant,
                            icon: Icon(Icons.add, color: colorScheme.primary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _participants.isEmpty ? null : () => Navigator.pop(context, _participants),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: const Text('Inizia Radio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addParticipant() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _participants.add(text);
      _controller.clear();
    });
  }
}

class YoutubeSearchPage extends StatefulWidget {
  final String participantName;
  final ThemeData themeData;
  const YoutubeSearchPage({super.key, required this.participantName, required this.themeData});
  @override
  State<YoutubeSearchPage> createState() => _YoutubeSearchPageState();
}

class _YoutubeSearchPageState extends State<YoutubeSearchPage> {
  final YoutubeExplode _yt = YoutubeExplode();
  final TextEditingController _controller = TextEditingController();
  List<Video> _results = [];
  bool _isSearching = false;

  Future<void> _search(String query) async {
    if (query.isEmpty) return;
    setState(() { _isSearching = true; _results = []; });
    try {
      var searchList = await _yt.search.getVideos(query);
      setState(() { _results = searchList.take(5).toList(); });
    } catch (e) {
      _showErrorDialog("Errore ricerca", "Impossibile cercare su YouTube.");
    } finally {
      setState(() => _isSearching = false);
    }
  }

  Future<void> _pasteLink() async {
    ClipboardData? clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    String? pastedText = clipboardData?.text?.trim();
    if (pastedText != null && pastedText.isNotEmpty) {
      try {
        Video video = await _yt.videos.get(pastedText);
        if (!mounted) return;
        Navigator.pop(context, PlaylistItem(participant: widget.participantName, url: video.url, thumbnailUrl: video.thumbnails.mediumResUrl));
      } catch (e) {
        if (!mounted) return;
        _showErrorDialog("Link non valido", "Impossibile recuperare i dettagli del video.");
      }
    }
  }

  Future<void> _showErrorDialog(String title, String message) async {
    if (!mounted) return;
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(child: const Text("Ok"), onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _yt.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.themeData.colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        centerTitle: true,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Cerca per ${widget.participantName}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Scegli un video YouTube', style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Salta', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Cerca su YouTube',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                          border: InputBorder.none,
                        ),
                        onSubmitted: _search,
                      ),
                    ),
                    IconButton(
                      onPressed: () => _search(_controller.text),
                      icon: Icon(Icons.search, color: colorScheme.primary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Risultati', style: TextStyle(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600)),
                  TextButton.icon(
                    onPressed: _pasteLink,
                    icon: Icon(Icons.link, color: colorScheme.primary),
                    label: Text('Incolla link', style: TextStyle(color: colorScheme.primary)),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.05),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                        ? Center(
                            child: Text(
                              'Nessun risultato. Scrivi qualcosa sopra per cercare.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white.withOpacity(0.7)),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              var video = _results[index];
                              return Material(
                                color: colorScheme.surface,
                                borderRadius: BorderRadius.circular(18),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: () async {
                                    if (video.duration != null && video.duration! > const Duration(minutes: 5)) {
                                      bool? confirm = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text("Canzone lunga"),
                                          content: const Text("La canzone è più lunga di 5 minuti. Vuoi aggiungerla comunque?"),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("No")),
                                            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Sì")),
                                          ],
                                        ),
                                      );
                                      if (confirm != true) return;
                                    }
                                    if (!mounted) return;
                                    Navigator.pop(context, PlaylistItem(participant: widget.participantName, url: video.url, thumbnailUrl: video.thumbnails.mediumResUrl));
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                                    child: Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(14),
                                          child: Image.network(video.thumbnails.lowResUrl, width: 82, height: 58, fit: BoxFit.cover),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                              const SizedBox(height: 6),
                                              Text(
                                                video.duration?.toString().split('.').first ?? "??:??",
                                                style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
