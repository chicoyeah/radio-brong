import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'checkpoint_storage.dart';
import 'spotify_utils.dart';
import 'soundcloud_utils.dart';
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
  String? _localAudioPath;
  bool _completionNotified = false;
  void Function(String)? onNotificationAction;

  MyAudioHandler() {
    _player.positionStream.listen(updatePosition);
    _player.playerStateStream.listen((state) {
      if (_localAudioPath == null) return;
      final completed = state.processingState == ja.ProcessingState.completed;
      playbackState.add(
        playbackState.value.copyWith(
          playing: state.playing,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          processingState: switch (state.processingState) {
            ja.ProcessingState.idle => AudioProcessingState.idle,
            ja.ProcessingState.loading => AudioProcessingState.loading,
            ja.ProcessingState.buffering => AudioProcessingState.buffering,
            ja.ProcessingState.ready => AudioProcessingState.ready,
            ja.ProcessingState.completed => AudioProcessingState.completed,
          },
          controls: state.playing
              ? [
                  MediaControl.skipToPrevious,
                  MediaControl.pause,
                  MediaControl.stop,
                  MediaControl.skipToNext,
                ]
              : [
                  MediaControl.skipToPrevious,
                  MediaControl.play,
                  MediaControl.stop,
                  MediaControl.skipToNext,
                ],
        ),
      );
      if (completed && !_completionNotified) {
        _completionNotified = true;
        onNotificationAction?.call('completed');
      }
    });
    playbackState.add(
      PlaybackState(
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
      ),
    );
  }

  @override
  Future<void> play() async {
    if (_localAudioPath != null) {
      unawaited(_player.play());
      return;
    }
    playbackState.add(
      playbackState.value.copyWith(
        playing: true,
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
      ),
    );
    onNotificationAction?.call('play');
  }

  @override
  Future<void> pause() async {
    if (_localAudioPath != null) {
      await _player.pause();
      return;
    }
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
      ),
    );
    onNotificationAction?.call('pause');
  }

  @override
  Future<void> stop() async {
    if (_localAudioPath != null) {
      await _player.stop();
      _localAudioPath = null;
    }
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.ready,
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
      ),
    );
    onNotificationAction?.call('stop');
  }

  Future<void> stopSilently() async {
    if (_localAudioPath != null) {
      await _player.stop();
      _localAudioPath = null;
    }
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.ready,
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    if (_localAudioPath != null) {
      await _player.seek(position);
    } else {
      onNotificationAction?.call('seek:${position.inSeconds}');
    }
  }

  Future<void> prepareExternalPlayback() async {
    _localAudioPath = null;
    await _player.stop();
  }

  Future<void> playLocalAudio(String path, TrackItem item) async {
    _localAudioPath = path;
    _completionNotified = false;
    updateMetadata(item);
    await _player.setFilePath(path);
    updateMetadata(item, duration: _player.duration);
    await play();
  }

  void updateExternalPlayback(bool playing, Duration position) {
    playbackState.add(
      playbackState.value.copyWith(
        playing: playing,
        updatePosition: position,
        processingState: AudioProcessingState.ready,
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
      ),
    );
  }

  @override
  Future<void> skipToNext() async {
    onNotificationAction?.call('next');
  }

  @override
  Future<void> skipToPrevious() async {
    onNotificationAction?.call('previous');
  }

  void updateMetadata(TrackItem item, {Duration? duration}) {
    mediaItem.add(
      MediaItem(
        id: item.videoId,
        album: "Radio Brong",
        title: item.title,
        artist: item.participantLabel,
        duration: duration ?? item.duration,
        artUri: item.thumbnailUrl != null
            ? Uri.parse(item.thumbnailUrl!)
            : null,
      ),
    );
  }

  void updatePosition(Duration position) {
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

  Future<void> disposePlayer() => _player.dispose();
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

  static const String _introPlaylistUrl =
      'https://www.youtube.com/playlist?list=PLBr8N5C2sDZI';

  late final WebViewController _webViewController;
  bool _soundCloudPlayerActive = false;
  Completer<void>? _blankWebViewLoadCompleter;
  VideoPlayerController? _localVideoController;
  String? _localVideoError;
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
  bool _isShowingOfflineError = false;
  bool _ageRestrictionNoticeShown = false;
  bool _ageRestrictedRedirectAttempted = false;
  bool _pendingAgeRestrictionLoginCheck = false;
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
    final isWebKitPlatform =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final webViewController = isWebKitPlatform
        ? WebViewController.fromPlatformCreationParams(
            WebKitWebViewControllerCreationParams(
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
              allowsInlineMediaPlayback: true,
            ),
          )
        : WebViewController();
    _webViewController = webViewController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'FlutterRadio',
        onMessageReceived: (JavaScriptMessage message) {
          if (message.message == 'videoEnded') {
            debugPrint("Video ended via JS channel");
            _nextTrack();
          } else if (message.message == 'soundcloudFinished') {
            _nextTrack();
          } else if (message.message == 'ageRestrictedLoginRequired') {
            _pendingAgeRestrictionLoginCheck = false;
            _showAgeRestrictionLoginNotice();
          } else if (message.message == 'openAgeRestrictedVideoOnYouTube') {
            _openAgeRestrictedVideoOnYouTube();
          } else if (message.message == 'videoPlaying') {
            if (!_isTransitioning &&
                _currentIndex >= 0 &&
                _currentIndex < _tracks.length) {
              final item = _tracks[_currentIndex];
              if (item.localPath == null) {
                _audioHandler.play();
              }
            }
          } else if (message.message == 'videoPaused') {
            if (!_isTransitioning &&
                _currentIndex >= 0 &&
                _currentIndex < _tracks.length) {
              final item = _tracks[_currentIndex];
              if (item.localPath == null) {
                _audioHandler.pause();
              }
            }
          } else if (message.message.startsWith('soundcloudDuration:')) {
            final durationMilliseconds = int.tryParse(
              message.message.substring('soundcloudDuration:'.length),
            );
            if (durationMilliseconds != null &&
                _currentIndex >= 0 &&
                _currentIndex < _tracks.length &&
                _tracks[_currentIndex].isSoundCloud) {
              _audioHandler.updateMetadata(
                _tracks[_currentIndex],
                duration: Duration(milliseconds: durationMilliseconds),
              );
            }
          } else if (message.message == 'unavailableDetected' ||
              message.message == 'unavailableDetectedNoLink') {
            debugPrint("Video unavailable detected: ${message.message}");
            _handleUnavailableVideo();
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (_isShowingOfflineError) {
              setState(() => _isShowingOfflineError = false);
            }
          },
          onPageFinished: (String url) {
            debugPrint('Page finished loading: $url');
            _lockWebViewZoom();
            if (url == 'about:blank') {
              final completer = _blankWebViewLoadCompleter;
              if (completer != null && !completer.isCompleted) {
                completer.complete();
              }
            }
            _checkPendingAgeRestrictionLogin(url);
            setState(() {
              _isTransitioning = false;
            });
            if (_currentIndex >= 0 &&
                _currentIndex < _tracks.length &&
                _tracks[_currentIndex].isSoundCloud) {
              return;
            }
            _webViewController.runJavaScript("""
              (function() {
                function checkAgeLoginPrompt() {
                  var text = document.body ? document.body.innerText : '';
                  function collectShadowText(root) {
                    var elements = root.querySelectorAll('*');
                    for (var i = 0; i < elements.length; i++) {
                      if (!elements[i].shadowRoot) continue;
                      text += ' ' + (elements[i].shadowRoot.innerText || '');
                      collectShadowText(elements[i].shadowRoot);
                    }
                  }
                  collectShadowText(document);
                  text = text.toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').replace(/[’‘]/g, String.fromCharCode(39)).replace(/\\s+/g, ' ');
                  var requiresAgeLogin = /accedi per confermare.{0,40}eta|sign in to confirm.{0,40}age|log in to confirm.{0,40}age/.test(text);
                  if (requiresAgeLogin && !window._radioAgeRestrictionNoticeSent) {
                    window._radioAgeRestrictionNoticeSent = true;
                    FlutterRadio.postMessage('ageRestrictedLoginRequired');
                  }
                }

                function setupVideo() {
                  checkAgeLoginPrompt();
                  var adultConfirmationText = 'capisco e desidero procedere';
                  function findAdultConfirmationButton(root) {
                    var buttons = root.querySelectorAll('button, [role="button"], a, tp-yt-paper-button, yt-button-shape');
                    var customButton = null;
                    for (var i = 0; i < buttons.length; i++) {
                      var button = buttons[i];
                      var label = ((button.innerText || button.textContent || '') + ' ' +
                        (button.getAttribute('aria-label') || '')).toLowerCase().replace(/\\s+/g, ' ').trim();
                      var rect = button.getBoundingClientRect();
                      if (label.includes(adultConfirmationText) && rect.width > 0 && rect.height > 0) {
                        if (button.matches('button, [role="button"], a')) return button;
                        customButton = customButton || button;
                      }
                    }
                    var hosts = root.querySelectorAll('*');
                    for (var j = 0; j < hosts.length; j++) {
                      if (!hosts[j].shadowRoot) continue;
                      var shadowButton = findAdultConfirmationButton(hosts[j].shadowRoot);
                      if (shadowButton) return shadowButton;
                    }
                    return customButton;
                  }
                  var confirmationButton = findAdultConfirmationButton(document);
                  if (confirmationButton && !window._radioAdultConfirmationClicked) {
                    window._radioAdultConfirmationClicked = true;
                    console.log('Adult content confirmation: proceeding');
                    confirmationButton.click();
                  } else if (!confirmationButton) {
                    window._radioAdultConfirmationClicked = false;
                  }

                  var pageText = (document.body ? document.body.innerText : '').toLowerCase().replace(/\\s+/g, ' ');
                  var ageError = document.querySelector('.ytp-error, .ytp-error-content, .ytp-error-message-container, .yt-playability-error-supported-renderers');
                  var ageErrorText = ageError ? ageError.innerText.toLowerCase().replace(/\\s+/g, ' ') : '';
                  pageText += ' ' + ageErrorText;
                  var isAgeRestricted = /age[- ]restricted|age restriction|spiacenti.{0,120}limiti di età|questi contenuti.{0,120}limiti di età|sorry.{0,120}age restricted|confirm your age|accedi per confermare l['’]et[aà]|accedi per confermare la tua età|conferma(re)? la tua età|confermare la tua età|video con limiti di età/.test(pageText);

                  if (isAgeRestricted) {
                    var needsAgeConfirmationLogin = /accedi per confermare l['’]et[aà]|sign in to confirm your age|log in to confirm your age/.test(pageText);
                    if (needsAgeConfirmationLogin && !window._radioAgeRestrictionNoticeSent) {
                      window._radioAgeRestrictionNoticeSent = true;
                      FlutterRadio.postMessage('ageRestrictedLoginRequired');
                    }
                    if ((location.hostname === 'youtube.com' || location.hostname === 'www.youtube.com') && location.pathname === '/watch') return;
                    if (!window._radioAgeRestrictedRedirectSent) {
                      window._radioAgeRestrictedRedirectSent = true;
                      FlutterRadio.postMessage('openAgeRestrictedVideoOnYouTube');
                    }
                    return;
                  }
                  window._radioAgeRestrictedRedirectSent = false;
                  window._radioAgeRestrictionNoticeSent = false;

                  var v = document.querySelector('video');
                  if (v) {
                    if (v.muted) v.muted = false;
                    if (v.volume === 0) v.volume = 1.0;

                    window._radioAdPlaybackUntil = window._radioAdPlaybackUntil || 0;
                    window._radioIsAdPlayback = function() {
                      var player = document.querySelector('.html5-video-player, #movie_player');
                      var adIsActive = !!(player && (
                        player.classList.contains('ad-showing') ||
                        player.classList.contains('ad-interrupting') ||
                        player.classList.contains('ad-showing-skip-button')
                      ));
                      if (adIsActive) window._radioAdPlaybackUntil = Date.now() + 2000;
                      return adIsActive || Date.now() < window._radioAdPlaybackUntil;
                    };
                    if (!window._radioAdPlaybackWatcher) {
                      window._radioAdPlaybackWatcher = window.setInterval(function() {
                        if (window._radioIsAdPlayback) window._radioIsAdPlayback();
                      }, 200);
                    }
                    function isAdPlayback() {
                      return window._radioIsAdPlayback();
                    }
                    
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
                        if (isAdPlayback()) {
                          console.log('Ad playback ended; keeping current track');
                          return;
                        }
                        console.log('Video ended event fired');
                        FlutterRadio.postMessage('videoEnded');
                      });

                      v.addEventListener('play', function() {
                        if (isAdPlayback()) return;
                        v._retryCount = 0;
                        FlutterRadio.postMessage('videoPlaying');
                      });

                      v.addEventListener('pause', function() {
                        if (isAdPlayback()) return;
                        FlutterRadio.postMessage('videoPaused');
                      });

                      v.addEventListener('error', function() {
                        console.log('Video playback error detected');
                        attemptPlaybackRetry();
                      });

                      v.addEventListener('timeupdate', function() {
                        if (isAdPlayback()) return;
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
                                  txt.includes('non è disponibile') ||
                                  txt.includes('age-restricted') ||
                                  txt.includes('age restricted') ||
                                  txt.includes('conferma la tua età');

                  if ((errVisible && hasErrTxt) || (btnVisible && hasErrTxt)) {
                    console.log('Unavailable video detected');
                    FlutterRadio.postMessage('unavailableDetected');
                  }
                }
                setupVideo();
                var observer = new MutationObserver(setupVideo);
                observer.observe(document.body, { childList: true, subtree: true });
                if (!window._radioAgeLoginPromptPoller) {
                  window._radioAgeLoginPromptPoller = window.setInterval(checkAgeLoginPrompt, 500);
                }
              })();
            """);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true ||
                !{
                  WebResourceErrorType.connect,
                  WebResourceErrorType.hostLookup,
                  WebResourceErrorType.io,
                  WebResourceErrorType.timeout,
                }.contains(error.errorType)) {
              return;
            }
            debugPrint(
              'Caricamento pagina fallito per un errore di rete: ${error.description}',
            );
            if (mounted) {
              setState(() => _isShowingOfflineError = true);
            }
          },
        ),
      );

    if (_webViewController.platform is AndroidWebViewController) {
      final androidController =
          _webViewController.platform as AndroidWebViewController;
      unawaited(androidController.setMediaPlaybackRequiresUserGesture(false));
      unawaited(androidController.enableZoom(false));
      unawaited(androidController.setUseWideViewPort(true));
    }
  }

  void _lockWebViewZoom() {
    unawaited(
      _webViewController.runJavaScript("""
        (function() {
          function enforceInitialScale() {
            var viewport = document.querySelector('meta[name="viewport"]');
            if (!viewport) {
              viewport = document.createElement('meta');
              viewport.name = 'viewport';
              (document.head || document.documentElement).appendChild(viewport);
            }
            var content = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no';
            if (viewport.content !== content) viewport.content = content;
          }
          enforceInitialScale();
          if (!window._radioZoomLockObserver) {
            window._radioZoomLockObserver = new MutationObserver(enforceInitialScale);
            window._radioZoomLockObserver.observe(document.head || document.documentElement, {
              childList: true,
              subtree: true,
              attributes: true,
              attributeFilter: ['content', 'name']
            });
            window.addEventListener('resize', enforceInitialScale);
            window.addEventListener('orientationchange', function() {
              enforceInitialScale();
              window.setTimeout(enforceInitialScale, 100);
            });
            document.addEventListener('gesturestart', function(event) {
              event.preventDefault();
            }, { passive: false });
            document.addEventListener('gesturechange', function(event) {
              event.preventDefault();
            }, { passive: false });
            document.addEventListener('touchmove', function(event) {
              if (event.touches.length > 1) event.preventDefault();
            }, { passive: false });
          }
        })();
      """),
    );
  }

  void _listenToMediaButtons() {
    bool? lastState;
    _audioHandler.playbackState.listen((state) {
      if (lastState == state.playing) return;
      lastState = state.playing;

      if (_currentIndex >= 0 &&
          _currentIndex < _tracks.length &&
          _tracks[_currentIndex].localPath != null) {
        return;
      }

      final isSoundCloudTrack =
          _currentIndex >= 0 &&
          _currentIndex < _tracks.length &&
          _tracks[_currentIndex].isSoundCloud;
      if (state.playing) {
        _webViewController.runJavaScript(
          isSoundCloudTrack
              ? "if (window._radioSoundCloudWidget) window._radioSoundCloudWidget.play();"
              : "document.querySelector('video')?.play()",
        );
      } else {
        _webViewController.runJavaScript(
          isSoundCloudTrack
              ? "if (window._radioSoundCloudWidget) window._radioSoundCloudWidget.pause();"
              : "document.querySelector('video')?.pause()",
        );
      }
    });

    _audioHandler.onNotificationAction = (String action) {
      if (action == 'next') _nextTrack();
      if (action == 'previous') _prevTrack();
      if (action == 'stop') unawaited(_internalStop());
      if (action == 'completed') _nextTrack();
      if ((action == 'play' || action == 'pause') &&
          _currentIndex >= 0 &&
          _currentIndex < _tracks.length &&
          _tracks[_currentIndex].isLocalVideo) {
        final controller = _localVideoController;
        if (controller?.value.isInitialized == true) {
          if (action == 'play') {
            unawaited(controller!.play());
          } else {
            unawaited(controller!.pause());
          }
        }
      }
      if (action.startsWith('seek:')) {
        final seconds = int.tryParse(action.split(':')[1]);
        if (seconds != null) {
          if (_currentIndex >= 0 &&
              _currentIndex < _tracks.length &&
              _tracks[_currentIndex].localPath != null &&
              _tracks[_currentIndex].isLocalVideo &&
              _localVideoController?.value.isInitialized == true) {
            _localVideoController!.seekTo(Duration(seconds: seconds));
          } else if (_currentIndex >= 0 &&
              _currentIndex < _tracks.length &&
              _tracks[_currentIndex].localPath == null) {
            final item = _tracks[_currentIndex];
            _webViewController.runJavaScript(
              item.isSoundCloud
                  ? "if (window._radioSoundCloudWidget) window._radioSoundCloudWidget.seekTo(${seconds * 1000});"
                  : "document.querySelector('video').currentTime = $seconds",
            );
          }
        }
      }
    };
  }

  void _setupConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final bool isConnected = results.any(
        (result) => result != ConnectivityResult.none,
      );
      if (isConnected && _isOffline && _isShowingOfflineError) {
        _reloadIfNecessary();
      }
      setState(() {
        _isOffline = !isConnected;
      });
    });
  }

  void _reloadIfNecessary() {
    if (_currentIndex != -1 && _isShowingOfflineError) {
      _isShowingOfflineError = false;
      _webViewController.reload();
    }
  }

  @override
  void dispose() {
    _yt.close();
    _videoStateTimer?.cancel();
    _connectivitySubscription?.cancel();
    _localVideoController?.dispose();
    _audioHandler.disposePlayer();
    super.dispose();
  }

  void _startVideoStatePolling() {
    _videoStateTimer?.cancel();
    _videoStateTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (_currentIndex == -1 ||
          _isProcessing ||
          _isTransitioning ||
          _tracks[_currentIndex].localPath != null) {
        return;
      }
      try {
        if (_tracks[_currentIndex].isSoundCloud) {
          final result = await _webViewController.runJavaScriptReturningResult(
            'window._radioSoundCloudPosition || 0',
          );
          final positionMilliseconds =
              double.tryParse(result.toString())?.toInt() ?? 0;
          _audioHandler.updatePosition(
            Duration(milliseconds: positionMilliseconds),
          );
          return;
        }

        final result = await _webViewController.runJavaScriptReturningResult(
          "var v = document.querySelector('video'); var ad = window._radioIsAdPlayback ? window._radioIsAdPlayback() : false; v ? ad + ',' + (v.ended || (v.duration > 1 && v.currentTime > 0 && v.currentTime >= v.duration - 0.5)) + ',' + v.currentTime : 'false,false,0'",
        );

        final parts = result.toString().replaceAll('"', '').split(',');
        if (parts.length >= 3) {
          final bool isAdPlayback = parts[0] == 'true';
          final bool ended = parts[1] == 'true';
          final double currentTime = double.tryParse(parts[2]) ?? 0;

          if (ended && !isAdPlayback) {
            debugPrint("Video ended detected via polling");
            _nextTrack();
          } else if (!isAdPlayback) {
            _audioHandler.updatePosition(
              Duration(seconds: currentTime.toInt()),
            );
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
                  if (!await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  )) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Impossibile aprire il link delle release.',
                        ),
                      ),
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
        .map(
          (track) => CheckpointTrack(
            participant: track.participant,
            videoId: track.videoId,
            title: track.title,
            thumbnailUrl: track.thumbnailUrl,
            durationSeconds: track.duration?.inSeconds,
            participantPosition: track.participantPosition,
            totalParticipants: track.totalParticipants,
            localPath: track.localPath,
            isLocalVideo: track.isLocalVideo,
          ),
        )
        .toList();

    await _checkpointStorage.saveCheckpoint(checkpointTracks, 0);
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
          .map(
            (track) => TrackItem(
              participant: track.participant,
              videoId: track.videoId,
              title: track.title,
              thumbnailUrl: track.thumbnailUrl,
              duration: track.durationSeconds != null
                  ? Duration(seconds: track.durationSeconds!)
                  : null,
              participantPosition: track.participantPosition,
              totalParticipants: track.totalParticipants,
              localPath: track.localPath,
              isLocalVideo: track.isLocalVideo,
            ),
          )
          .toList();
      _playlist = [];
      _currentIndex = 0;
      _isProcessing = false;
      _isTransitioning = true;
      _autoRedirectAttempted = false;
      _ageRestrictionNoticeShown = false;
      _ageRestrictedRedirectAttempted = false;
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
    final result = await Navigator.of(context).push<ParticipantSelectionResult>(
      MaterialPageRoute(
        builder: (context) => ParticipantSelectorPage(
          initialList: _lastParticipants,
          themeData: themeData,
        ),
        fullscreenDialog: true,
      ),
    );
    if (result != null && result.participants.isNotEmpty) {
      _lastParticipants = List.from(result.participants);
      final participants = result.randomize
          ? (List<String>.from(result.participants)..shuffle())
          : result.participants;
      await _collectSongs(participants);
    }
  }

  Future<String?> _pickRandomIntroUrl() async {
    try {
      final playlistId = extractPlaylistIdFromUrl(_introPlaylistUrl);
      if (playlistId == null) {
        throw Exception('Playlist ID non trovata');
      }

      final response = await http.get(
        Uri.parse('https://www.youtube.com/playlist?list=$playlistId'),
      );
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
    int i = 0;
    while (i < participants.length) {
      final p = participants[i];
      final PlaylistItem? item = await Navigator.of(context).push<PlaylistItem>(
        MaterialPageRoute(
          builder: (context) =>
              YoutubeSearchPage(participantName: p, themeData: themeData),
          fullscreenDialog: true,
        ),
      );

      if (item == null) {
        i += 1;
        continue;
      }

      if (item.isBack) {
        if (i == 0) {
          return;
        }
        newPlaylist.removeWhere(
          (playlistItem) => playlistItem.participantPosition == i,
        );
        i -= 1;
        continue;
      }

      newPlaylist.add(
        PlaylistItem(
          participant: item.participant,
          url: item.url,
          videoId: item.videoId,
          thumbnailUrl: item.thumbnailUrl,
          localPath: item.localPath,
          isLocalVideo: item.isLocalVideo,
          localTitle: item.localTitle,
          participantPosition: i + 1,
          totalParticipants: participants.length,
        ),
      );
      i += 1;
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
      if (_tracks.isNotEmpty) {
        _currentIndex = 0;
        await _playCurrent();
      }
    }
  }

  Future<void> _processItem(int index) async {
    final item = _playlist[index];
    if (item.localPath != null) {
      _addTrack(
        item,
        videoId: 'local:${item.localPath}',
        title: item.localTitle ?? File(item.localPath!).uri.pathSegments.last,
        localPath: item.localPath,
        isLocalVideo: item.isLocalVideo,
      );
      return;
    }
    final soundCloudUrl = extractSoundCloudTrackUrl(item.url);
    if (soundCloudUrl != null) {
      final pathSegments = Uri.parse(
        soundCloudUrl,
      ).pathSegments.where((segment) => segment.isNotEmpty);
      final title = pathSegments.isNotEmpty
          ? pathSegments.last.replaceAll('-', ' ')
          : item.participant;
      _addTrack(
        item,
        videoId: soundCloudUrl,
        title: title.isEmpty ? item.participant : title,
      );
      return;
    }
    try {
      final video = await _yt.videos.get(item.url);
      _addTrack(
        item,
        videoId: video.id.value,
        title: video.title,
        thumbnailUrl: video.thumbnails.mediumResUrl,
        duration: video.duration,
      );
    } catch (e) {
      debugPrint("Metadata error: $e");
      if (item.videoId != null) {
        _addTrack(item, videoId: item.videoId!, title: item.participant);
      }
    }
  }

  void _addTrack(
    PlaylistItem item, {
    required String videoId,
    required String title,
    String? thumbnailUrl,
    Duration? duration,
    String? localPath,
    bool isLocalVideo = false,
  }) {
    if (!mounted) return;
    setState(() {
      _tracks.add(
        TrackItem(
          participant: item.participant,
          videoId: videoId,
          title: title,
          thumbnailUrl: thumbnailUrl,
          duration: duration,
          localPath: localPath,
          isLocalVideo: isLocalVideo,
          participantPosition: item.participantPosition,
          totalParticipants: item.totalParticipants,
        ),
      );
    });
  }

  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _tracks.length) return;
    setState(() {
      _isTransitioning = true;
      _autoRedirectAttempted = false;
      _ageRestrictedRedirectAttempted = false;
      _ageRestrictionNoticeShown = false;
      _pendingAgeRestrictionLoginCheck = false;
      _volumeBoost = 1.0;
    });
    TrackItem item = _tracks[_currentIndex];
    await _stopSoundCloudPlayer();
    await _stopAndDisposeLocalVideo();
    await _audioHandler.prepareExternalPlayback();
    _audioHandler.updateMetadata(item);
    _audioHandler.updatePosition(Duration.zero);
    await _saveCheckpoint();

    if (item.localPath != null) {
      _localVideoError = null;
      final localFile = File(item.localPath!);
      if (!await localFile.exists()) {
        if (!mounted) return;
        setState(() => _isTransitioning = false);
        await _showLocalMediaError(
          'File non disponibile',
          'Il file selezionato non è più disponibile sul dispositivo.',
        );
        return;
      }

      if (item.isLocalVideo) {
        final controller = VideoPlayerController.file(localFile);
        setState(() {
          _localVideoController = controller;
        });
        controller.addListener(() {
          if (!mounted || _localVideoController != controller) return;
          final value = controller.value;
          if (value.hasError) {
            if (_localVideoError != value.errorDescription) {
              setState(() {
                _localVideoError =
                    value.errorDescription ?? 'Errore di riproduzione video.';
              });
            }
            return;
          }
          if (value.isInitialized && _isTransitioning) {
            setState(() => _isTransitioning = false);
          }
          if (value.isInitialized) {
            _audioHandler.updateExternalPlayback(
              value.isPlaying,
              value.position,
            );
          }
          if (value.isCompleted &&
              !_isTransitioning &&
              _currentIndex >= 0 &&
              _currentIndex < _tracks.length &&
              _tracks[_currentIndex].localPath != null &&
              _tracks[_currentIndex].isLocalVideo) {
            _nextTrack();
          }
        });
        try {
          await controller.initialize().timeout(const Duration(seconds: 30));
          if (!mounted || _localVideoController != controller) return;
          await controller.setLooping(false);
          _audioHandler.updateMetadata(
            item,
            duration: controller.value.duration,
          );
          await controller.play();
        } catch (error) {
          debugPrint('Impossibile riprodurre il video locale: $error');
          _localVideoController = null;
          await controller.dispose();
          if (!mounted) return;
          setState(() {
            _isTransitioning = false;
            _localVideoError = error is TimeoutException
                ? 'Il video non ha terminato il caricamento.'
                : 'Il formato video non è supportato o il file è danneggiato.';
          });
          await _showLocalMediaError(
            'Impossibile riprodurre il video',
            _localVideoError!,
          );
        }
      } else {
        try {
          await _audioHandler.playLocalAudio(item.localPath!, item);
          if (mounted) setState(() => _isTransitioning = false);
        } catch (error) {
          debugPrint('Impossibile riprodurre l’audio locale: $error');
          if (!mounted) return;
          setState(() => _isTransitioning = false);
          await _showLocalMediaError(
            'Impossibile riprodurre l’audio',
            'Il formato del file audio potrebbe non essere supportato.',
          );
        }
      }
      return;
    }

    if (item.isSoundCloud) {
      _audioHandler.play();
      _soundCloudPlayerActive = true;
      await _webViewController.loadHtmlString(
        _soundCloudPlayerHtml(item.videoId),
        baseUrl: 'https://radio-brong.local',
      );
      return;
    }

    _audioHandler.play();
    final url = 'https://www.yout-ube.com/watch?v=${item.videoId}';
    await _webViewController.loadRequest(Uri.parse(url));
  }

  String _soundCloudPlayerHtml(String trackUrl) {
    final embedUrl = soundCloudEmbedUri(trackUrl).toString();
    return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no">
  <style>
    html, body { margin: 0; width: 100%; height: 100%; background: #000; }
    iframe { display: block; width: 100%; height: 100%; border: 0; }
  </style>
</head>
<body>
  <iframe id="soundcloud-player" allow="autoplay"
    src="$embedUrl"></iframe>
  <script src="https://w.soundcloud.com/player/api.js"></script>
  <script>
    (function() {
      function connectPlayer() {
        if (!window.SC || !window.SC.Widget) {
          window.setTimeout(connectPlayer, 100);
          return;
        }
        var widget = SC.Widget(document.getElementById('soundcloud-player'));
        window._radioSoundCloudWidget = widget;
        window._radioSoundCloudPosition = 0;
        widget.bind(SC.Widget.Events.READY, function() {
          widget.getDuration(function(duration) {
            FlutterRadio.postMessage('soundcloudDuration:' + duration);
          });
          widget.bind(SC.Widget.Events.PLAY, function() {
            FlutterRadio.postMessage('videoPlaying');
          });
          widget.bind(SC.Widget.Events.PAUSE, function() {
            FlutterRadio.postMessage('videoPaused');
          });
          widget.bind(SC.Widget.Events.FINISH, function() {
            FlutterRadio.postMessage('soundcloudFinished');
          });
          widget.bind(SC.Widget.Events.PLAY_PROGRESS, function(event) {
            window._radioSoundCloudPosition = event.currentPosition;
          });
          widget.play();
        });
      }
      connectPlayer();
    })();
  </script>
</body>
</html>
''';
  }

  Future<void> _showLocalMediaError(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Ok'),
          ),
        ],
      ),
    );
  }

  void _handleUnavailableVideo() {
    if (_autoRedirectAttempted || _currentIndex == -1) return;
    _autoRedirectAttempted = true;
    _pendingAgeRestrictionLoginCheck = true;
    TrackItem item = _tracks[_currentIndex];
    final youtubeUrl = 'https://www.youtube.com/watch?v=${item.videoId}';
    _webViewController.loadRequest(Uri.parse(youtubeUrl));
  }

  void _openAgeRestrictedVideoOnYouTube() {
    if (_ageRestrictedRedirectAttempted || _currentIndex == -1) return;
    _ageRestrictedRedirectAttempted = true;
    _pendingAgeRestrictionLoginCheck = true;
    final item = _tracks[_currentIndex];
    final youtubeUrl = Uri.https('www.youtube.com', '/watch', {
      'v': item.videoId,
    });
    _webViewController.loadRequest(youtubeUrl);
  }

  Future<void> _checkPendingAgeRestrictionLogin(String url) async {
    if (!_pendingAgeRestrictionLoginCheck) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.host != 'youtube.com' && uri.host != 'www.youtube.com') ||
        uri.path != '/watch') {
      return;
    }

    try {
      for (var attempt = 0; attempt < 40; attempt++) {
        final result = await _webViewController.runJavaScriptReturningResult(
          "(() => { const value = window.ytcfg && typeof window.ytcfg.get === 'function' ? window.ytcfg.get('LOGGED_IN') : null; if (value === true || value === 1 || (typeof value === 'string' && ['true', '1'].includes(value.toLowerCase()))) return 'logged-in'; let text = (document.body && document.body.innerText || '') + ' ' + (document.querySelector('.ytp-error, .ytp-error-content, .ytp-error-message-container, .yt-playability-error-supported-renderers')?.innerText || ''); const collectShadowText = root => { for (const node of root.querySelectorAll('*')) if (node.shadowRoot) { text += ' ' + (node.shadowRoot.innerText || ''); collectShadowText(node.shadowRoot); } }; collectShadowText(document); text = text.toLowerCase().normalize('NFD').replace(/[\\\\u0300-\\\\u036f]/g, '').replace(/[’‘]/g, \"'\").replace(/\\\\s+/g, ' '); if (/accedi per confermare l'eta|accedi per confermare eta|sign in to confirm your age|log in to confirm your age/.test(text)) return 'logged-out'; return 'unknown'; })()",
        );
        final loginState = result.toString().replaceAll('"', '').toLowerCase();
        if (loginState == 'logged-in') {
          _pendingAgeRestrictionLoginCheck = false;
          return;
        }
        if (loginState == 'logged-out') {
          _pendingAgeRestrictionLoginCheck = false;
          _showAgeRestrictionLoginNotice();
          return;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted || !_pendingAgeRestrictionLoginCheck) return;
      }
      debugPrint(
        'Stato di accesso YouTube non rilevabile dopo il redirect age-restricted.',
      );
      _pendingAgeRestrictionLoginCheck = false;
    } catch (error) {
      debugPrint('Impossibile verificare il login YouTube: $error');
      _pendingAgeRestrictionLoginCheck = false;
    }
  }

  void _showAgeRestrictionLoginNotice() {
    if (!mounted || _ageRestrictionNoticeShown) return;
    _ageRestrictionNoticeShown = true;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Accesso a YouTube richiesto'),
        content: const Text(
          'Per guardare i video con limiti di età devi accedere a YouTube.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Ok'),
          ),
        ],
      ),
    );
  }

  void _setVolumeBoost(double boost) {
    setState(() {
      _volumeBoost = boost;
    });
    _webViewController.runJavaScript(
      "window._radioVolumeBooster && (window._radioVolumeBooster.gain.value = $boost)",
    );
  }

  Future<void> _openVolumeBoosterSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: _seasonalSurfaceColor,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        double localBoost = _volumeBoost;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              top: false,
              child: Padding(
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
                        Text(
                          'Boost: x${localBoost.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextButton(
                          onPressed: () {
                            setSheetState(() => localBoost = 1.0);
                            _setVolumeBoost(1.0);
                          },
                          child: const Text(
                            'Reset',
                            style: TextStyle(color: Colors.white),
                          ),
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Chiudi',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildControlButton(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    required bool compact,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: compact ? 52 : 72,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Center(
            child: Icon(icon, color: Colors.white, size: compact ? 24 : 28),
          ),
        ),
      ),
    );
  }

  String _formatPlaybackTime(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Future<void> _seekLocalVideo(Duration target) async {
    final controller = _localVideoController;
    if (controller == null || !controller.value.isInitialized) return;

    final wasPlaying = controller.value.isPlaying;
    await controller.seekTo(target);
    if (wasPlaying &&
        mounted &&
        identical(_localVideoController, controller) &&
        !controller.value.isPlaying) {
      await controller.play();
    }
  }

  Widget _buildLocalMediaControls(TrackItem item) {
    return StreamBuilder<PlaybackState>(
      stream: _audioHandler.playbackState,
      initialData: _audioHandler.playbackState.value,
      builder: (context, snapshot) {
        final playbackState =
            snapshot.data ?? _audioHandler.playbackState.value;
        final isPlaying = playbackState.playing;
        final duration = item.isLocalVideo
            ? _localVideoController?.value.duration ?? Duration.zero
            : _audioHandler.mediaItem.value?.duration ?? Duration.zero;
        final position = playbackState.updatePosition;
        final maxMilliseconds = duration.inMilliseconds;
        final sliderValue = maxMilliseconds > 0
            ? position.inMilliseconds.clamp(0, maxMilliseconds).toDouble()
            : 0.0;

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            color: _seasonalSurfaceColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: sliderValue,
                max: maxMilliseconds > 0 ? maxMilliseconds.toDouble() : 1,
                activeColor: _seasonalButtonColor,
                inactiveColor: Colors.white24,
                onChanged: maxMilliseconds > 0
                    ? (value) {
                        final target = Duration(milliseconds: value.round());
                        if (item.isLocalVideo) {
                          unawaited(_seekLocalVideo(target));
                        } else {
                          _audioHandler.seek(target);
                        }
                      }
                    : null,
              ),
              Row(
                children: [
                  Text(
                    _formatPlaybackTime(position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {
                      if (isPlaying) {
                        _audioHandler.pause();
                      } else {
                        _audioHandler.play();
                      }
                    },
                    tooltip: isPlaying ? 'Pausa' : 'Riprendi',
                    icon: Icon(
                      isPlaying ? Icons.pause_circle : Icons.play_circle,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatPlaybackTime(duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _stopSoundCloudPlayer() async {
    if (!_soundCloudPlayerActive) return;
    _soundCloudPlayerActive = false;
    await _webViewController.runJavaScript(
      'if (window._radioSoundCloudWidget) window._radioSoundCloudWidget.pause();',
    );
    await _loadBlankWebView();
  }

  Future<void> _loadBlankWebView() async {
    final completer = Completer<void>();
    _blankWebViewLoadCompleter = completer;
    try {
      await _webViewController.loadRequest(Uri.parse('about:blank'));
      await completer.future.timeout(const Duration(seconds: 5));
      await WidgetsBinding.instance.endOfFrame;
    } catch (error, stackTrace) {
      debugPrint('Impossibile arrestare la pagina multimediale: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (identical(_blankWebViewLoadCompleter, completer)) {
        _blankWebViewLoadCompleter = null;
      }
    }
  }

  Future<void> _internalStop() async {
    final hadSoundCloudPlayer = _soundCloudPlayerActive;
    await _stopSoundCloudPlayer();
    if (!hadSoundCloudPlayer) {
      await _webViewController.loadRequest(Uri.parse('about:blank'));
    }
    unawaited(_audioHandler.stopSilently());
    unawaited(_stopAndDisposeLocalVideo());
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
        content: const Text(
          "Vuoi davvero interrompere la radio e cancellare la playlist attuale?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("No"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Sì"),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _internalStop();
      _audioHandler.stopSilently();
    }
  }

  Future<void> _nextTrack() async {
    final now = DateTime.now();
    if (_lastTrackChange != null &&
        now.difference(_lastTrackChange!) < const Duration(seconds: 2)) {
      return;
    }
    _lastTrackChange = now;

    if (_currentIndex + 1 < _tracks.length) {
      final previousItem = _tracks[_currentIndex];
      setState(() {
        _currentIndex++;
      });
      final nextItem = _tracks[_currentIndex];
      if (previousItem.localPath == null &&
          nextItem.localPath != null &&
          nextItem.isLocalVideo) {
        await WidgetsBinding.instance.endOfFrame;
      }
      await _playCurrent();
    } else if (!_isProcessing) {
      await _stopSoundCloudPlayer();
      await _stopAndDisposeLocalVideo();
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

  Future<void> _stopAndDisposeLocalVideo() async {
    final controller = _localVideoController;
    _localVideoController = null;
    if (controller == null) return;

    if (controller.value.isInitialized && controller.value.isPlaying) {
      await controller.pause();
    }
    await controller.dispose();
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
    final screenSize = MediaQuery.sizeOf(context);
    final compact = screenSize.height < 500;
    TrackItem? currentItem =
        (_currentIndex >= 0 && _currentIndex < _tracks.length)
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
          toolbarHeight: compact ? 56 : 88,
          title: Image.asset(
            _selectedLogo,
            height: compact ? 52 : 84,
            fit: BoxFit.contain,
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            if (_currentIndex != -1 && _tracks[_currentIndex].localPath == null)
              IconButton(
                onPressed: _openVolumeBoosterSheet,
                icon: Icon(Icons.volume_up, color: Colors.white),
                tooltip: 'Booster',
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: screenSize.width < 600 ? 8 : 16,
                vertical: compact ? 4 : 8,
              ),
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
                            if (_currentIndex != -1 &&
                                currentItem?.isLocalVideo == true)
                              _localVideoController != null
                                  ? ValueListenableBuilder<VideoPlayerValue>(
                                      valueListenable: _localVideoController!,
                                      builder: (context, value, child) {
                                        if (value.hasError) {
                                          return Center(
                                            child: Padding(
                                              padding: const EdgeInsets.all(24),
                                              child: Text(
                                                value.errorDescription ??
                                                    'Errore di riproduzione video.',
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                        if (!value.isInitialized) {
                                          return const Center(
                                            child: CircularProgressIndicator(),
                                          );
                                        }
                                        return Center(
                                          child: GestureDetector(
                                            onTap: () {
                                              if (value.isPlaying) {
                                                _audioHandler.pause();
                                              } else {
                                                _audioHandler.play();
                                              }
                                            },
                                            child: Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                AspectRatio(
                                                  aspectRatio:
                                                      value.aspectRatio,
                                                  child: child,
                                                ),
                                                if (!value.isPlaying)
                                                  const Icon(
                                                    Icons.play_circle_fill,
                                                    size: 72,
                                                    color: Colors.white70,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                      child: VideoPlayer(
                                        _localVideoController!,
                                      ),
                                    )
                                  : _localVideoError != null
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Text(
                                          _localVideoError!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    )
                                  : const Center(
                                      child: CircularProgressIndicator(),
                                    )
                            else if (_currentIndex != -1 &&
                                currentItem?.localPath != null)
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.audiotrack,
                                      size: 96,
                                      color: Colors.white70,
                                    ),
                                    const SizedBox(height: 16),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Text(
                                        currentItem!.title,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else if (_currentIndex != -1)
                              WebViewWidget(controller: _webViewController)
                            else
                              Container(
                                color: _seasonalSurfaceColor,
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.radio,
                                        size: compact ? 56 : 96,
                                        color: Colors.white.withOpacity(0.18),
                                      ),
                                      SizedBox(height: compact ? 4 : 12),
                                      Text(
                                        "Nessun brano in riproduzione",
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.7),
                                          fontSize: compact ? 14 : 16,
                                        ),
                                      ),
                                      SizedBox(height: compact ? 2 : 8),
                                      Text(
                                        "Premi il pulsante qui sotto per iniziare",
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.55),
                                          fontSize: 13,
                                        ),
                                      ),
                                      SizedBox(height: compact ? 8 : 20),
                                      Column(
                                        children: [
                                          ElevatedButton.icon(
                                            onPressed: _isProcessing
                                                ? null
                                                : _openParticipantSelector,
                                            icon: Icon(
                                              Icons.playlist_play,
                                              color: Colors.white,
                                            ),
                                            label: const Text(
                                              'Avvia playlist',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  _seasonalButtonColor,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(18),
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 24,
                                                    vertical: 14,
                                                  ),
                                            ),
                                          ),
                                          if (_hasCheckpoint) ...[
                                            const SizedBox(height: 12),
                                            OutlinedButton.icon(
                                              onPressed: _resumeFromCheckpoint,
                                              icon: const Icon(
                                                Icons.restart_alt,
                                                color: Colors.white,
                                              ),
                                              label: const Text(
                                                'Riprendi dal checkpoint',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                side: BorderSide(
                                                  color: _seasonalButtonColor,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(18),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 20,
                                                      vertical: 12,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if ((currentItem?.participant ?? '')
                                .trim()
                                .isNotEmpty)
                              Positioned(
                                top: 16,
                                left: 16,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.35),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.08),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.person,
                                        color: Colors.white.withOpacity(0.9),
                                        size: 16,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        currentItem!.participantLabel,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                      if (_volumeBoost > 1.0) ...[
                                        const SizedBox(width: 10),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _seasonalButtonColor
                                                .withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Text(
                                            'x${_volumeBoost.toStringAsFixed(2)}',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.95,
                                              ),
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            if (_isOffline && currentItem?.localPath == null)
                              Positioned(
                                top: 16,
                                left: 16,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent.withOpacity(0.88),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Text(
                                    'Offline',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (currentItem?.localPath != null) ...[
                    SizedBox(height: compact ? 4 : 12),
                    _buildLocalMediaControls(currentItem!),
                  ],
                  SizedBox(height: compact ? 6 : 20),
                  SafeArea(
                    top: false,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildControlButton(
                          Icons.skip_previous,
                          'Precedente',
                          _prevTrack,
                          compact: compact,
                        ),
                        SizedBox(width: compact ? 6 : 10),
                        _buildControlButton(
                          Icons.stop,
                          'Stop',
                          _stopAudio,
                          compact: compact,
                        ),
                        SizedBox(width: compact ? 6 : 10),
                        _buildControlButton(
                          Icons.skip_next,
                          'Successivo',
                          _nextTrack,
                          compact: compact,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: compact ? 4 : 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlaylistItem {
  final String participant;
  final String url;
  final String? videoId;
  final String? thumbnailUrl;
  final String? localPath;
  final String? localTitle;
  final bool isLocalVideo;
  final int? participantPosition;
  final int? totalParticipants;
  final bool isCancelled;
  final bool isBack;

  PlaylistItem({
    required this.participant,
    required this.url,
    this.videoId,
    this.thumbnailUrl,
    this.localPath,
    this.localTitle,
    this.isLocalVideo = false,
    this.participantPosition,
    this.totalParticipants,
    this.isCancelled = false,
    this.isBack = false,
  });

  static PlaylistItem cancelled(String participant) {
    return PlaylistItem(participant: participant, url: '', isCancelled: true);
  }

  static PlaylistItem back(String participant) {
    return PlaylistItem(participant: participant, url: '', isBack: true);
  }
}

class TrackItem {
  final String participant;
  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final Duration? duration;
  final String? localPath;
  final bool isLocalVideo;
  final int? participantPosition;
  final int? totalParticipants;
  bool get isSoundCloud => extractSoundCloudTrackUrl(videoId) != null;

  TrackItem({
    required this.participant,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
    this.duration,
    this.localPath,
    this.isLocalVideo = false,
    this.participantPosition,
    this.totalParticipants,
  });

  String get participantLabel {
    if (participantPosition == null || totalParticipants == null) {
      return participant;
    }
    return '$participant · $participantPosition/$totalParticipants';
  }
}

class ParticipantSelectionResult {
  final List<String> participants;
  final bool randomize;

  const ParticipantSelectionResult({
    required this.participants,
    required this.randomize,
  });
}

class ParticipantSelectorPage extends StatefulWidget {
  final List<String> initialList;
  final ThemeData themeData;
  const ParticipantSelectorPage({
    super.key,
    required this.initialList,
    required this.themeData,
  });
  @override
  State<ParticipantSelectorPage> createState() =>
      _ParticipantSelectorPageState();
}

class _ParticipantSelectorPageState extends State<ParticipantSelectorPage> {
  late List<String> _participants;
  bool _randomizeParticipants = true;
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

  void _reorderParticipants(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final participant = _participants.removeAt(oldIndex);
      _participants.insert(newIndex, participant);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.themeData.colorScheme;
    final compact = MediaQuery.sizeOf(context).height < 500;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        centerTitle: true,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'Seleziona partecipanti',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Aggiungi nomi e avvia la radio',
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 13,
              ),
            ),
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: EdgeInsets.all(compact ? 8 : 16),
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
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                    ),
                                  ),
                                )
                              : ReorderableListView.builder(
                                  buildDefaultDragHandles: false,
                                  onReorder: _reorderParticipants,
                                  itemCount: _participants.length,
                                  itemBuilder: (context, index) {
                                    return Padding(
                                      key: ValueKey(_participants[index]),
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: Material(
                                        color: colorScheme.surface,
                                        borderRadius: BorderRadius.circular(18),
                                        child: ListTile(
                                          title: Text(
                                            _participants[index],
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.delete,
                                                  color: Colors.white70,
                                                ),
                                                onPressed: () => setState(
                                                  () => _participants.removeAt(
                                                    index,
                                                  ),
                                                ),
                                              ),
                                              if (!_randomizeParticipants)
                                                ReorderableDragStartListener(
                                                  index: index,
                                                  child: const Padding(
                                                    padding: EdgeInsets.all(8),
                                                    child: Icon(
                                                      Icons.drag_handle,
                                                      color: Colors.white70,
                                                    ),
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
                        SizedBox(height: compact ? 6 : 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    hintText: 'Nome partecipante',
                                    hintStyle: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                    ),
                                    border: InputBorder.none,
                                  ),
                                  onSubmitted: (_) => _addParticipant(),
                                ),
                              ),
                              IconButton(
                                tooltip: _randomizeParticipants
                                    ? 'Randomizzazione attiva'
                                    : 'Randomizzazione disattivata',
                                onPressed: () => setState(
                                  () => _randomizeParticipants =
                                      !_randomizeParticipants,
                                ),
                                icon: Icon(
                                  Icons.shuffle,
                                  color: _randomizeParticipants
                                      ? colorScheme.primary
                                      : Colors.white70,
                                ),
                              ),
                              IconButton(
                                onPressed: _addParticipant,
                                icon: Icon(
                                  Icons.add,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: compact ? 6 : 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _participants.isEmpty
                          ? null
                          : () => Navigator.pop(
                              context,
                              ParticipantSelectionResult(
                                participants: List.from(_participants),
                                randomize: _randomizeParticipants,
                              ),
                            ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          vertical: compact ? 10 : 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: const Text(
                        'Inizia Radio',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _addParticipant() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final normalizedName = text.toLowerCase();
    if (_participants.any(
      (participant) => participant.trim().toLowerCase() == normalizedName,
    )) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Hai già aggiunto "$text".')));
      return;
    }
    setState(() {
      _participants.add(text);
      _controller.clear();
    });
  }
}

class YoutubeSearchPage extends StatefulWidget {
  final String participantName;
  final ThemeData themeData;
  const YoutubeSearchPage({
    super.key,
    required this.participantName,
    required this.themeData,
  });
  @override
  State<YoutubeSearchPage> createState() => _YoutubeSearchPageState();
}

class _YoutubeSearchPageState extends State<YoutubeSearchPage> {
  final YoutubeExplode _yt = YoutubeExplode();
  final TextEditingController _controller = TextEditingController();
  List<Video> _results = [];
  List<String> _suggestions = [];
  Timer? _suggestionDebounce;
  int _suggestionRequestId = 0;
  bool _isSearching = false;
  String _lastSearchQuery = '';

  void _onQueryChanged(String query) {
    _suggestionDebounce?.cancel();
    final requestId = ++_suggestionRequestId;
    final normalizedQuery = query.trim();
    setState(() => _suggestions = []);
    if (normalizedQuery.length < 2 ||
        extractSoundCloudTrackUrl(normalizedQuery) != null ||
        extractSpotifyTrackUrl(normalizedQuery) != null) {
      return;
    }
    _suggestionDebounce = Timer(const Duration(milliseconds: 300), () {
      _loadSuggestions(normalizedQuery, requestId);
    });
  }

  Future<void> _loadSuggestions(String query, int requestId) async {
    try {
      final response = await http
          .get(
            Uri.https('suggestqueries.google.com', '/complete/search', {
              'client': 'firefox',
              'ds': 'yt',
              'hl': 'it',
              'q': query,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        debugPrint(
          'Suggerimenti YouTube non disponibili: HTTP ${response.statusCode}',
        );
        return;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.length < 2 || decoded[1] is! List) {
        debugPrint('Risposta dei suggerimenti YouTube non valida.');
        return;
      }
      final suggestions = (decoded[1] as List)
          .whereType<String>()
          .where((suggestion) => suggestion.isNotEmpty)
          .take(6)
          .toList();
      if (!mounted || requestId != _suggestionRequestId) return;
      setState(() => _suggestions = suggestions);
    } catch (error) {
      debugPrint('Impossibile caricare i suggerimenti YouTube: $error');
    }
  }

  Future<void> _search(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return;
    _suggestionDebounce?.cancel();
    _suggestionRequestId++;
    setState(() {
      _lastSearchQuery = normalizedQuery;
      _suggestions = [];
      _isSearching = true;
      _results = [];
    });
    const maxAttempts = 3;
    try {
      final videoId = extractYoutubeVideoIdFromUrl(normalizedQuery);
      final soundCloudUrl = extractSoundCloudTrackUrl(normalizedQuery);
      if (soundCloudUrl != null) {
        String resolvedSoundCloudUrl;
        try {
          resolvedSoundCloudUrl = await resolveSoundCloudTrackUrl(
            soundCloudUrl,
          );
        } catch (error) {
          debugPrint('Impossibile risolvere il link SoundCloud: $error');
          if (mounted) {
            await _showErrorDialog(
              'Link SoundCloud non valido',
              'Non è stato possibile aprire il link condiviso. Controlla la '
                  'connessione e verifica che il link punti a una traccia.',
            );
          }
          return;
        }
        if (mounted) {
          Navigator.pop(
            context,
            PlaylistItem(
              participant: widget.participantName,
              url: resolvedSoundCloudUrl,
            ),
          );
        }
        return;
      }

      final spotifyUrl = extractSpotifyTrackUrl(normalizedQuery);
      if (spotifyUrl != null) {
        try {
          final track = await loadSpotifyTrack(spotifyUrl);
          final videos = await _yt.search.getVideos(track.searchQuery);
          if (!mounted) return;
          if (videos.isEmpty) {
            await _showErrorDialog(
              'Brano non trovato su YouTube',
              'Non è stato trovato un video per "${track.title}" di '
                  '${track.artist}.',
            );
            return;
          }
          await _selectVideo(videos.first);
        } catch (error) {
          debugPrint('Impossibile cercare il brano Spotify su YouTube: $error');
          if (mounted) {
            await _showErrorDialog(
              'Link Spotify non valido',
              'Non è stato possibile recuperare il brano e cercarlo su '
                  'YouTube. Verifica il link e la connessione.',
            );
          }
        }
        return;
      }

      if (videoId != null) {
        try {
          final video = await _yt.videos.get(videoId);
          if (!mounted) return;
          await _selectVideo(video);
        } catch (error) {
          debugPrint('Impossibile recuperare il video dal link: $error');
          if (mounted) {
            await _showErrorDialog(
              'Link non valido',
              'Impossibile recuperare i dettagli del video.',
            );
          }
        }
        return;
      }

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          var searchList = await _yt.search.getVideos(normalizedQuery);
          if (!mounted) return;
          setState(() {
            _results = searchList.take(5).toList();
          });
          break;
        } catch (e) {
          if (attempt == maxAttempts) {
            if (mounted) {
              _showErrorDialog(
                "Errore ricerca",
                "Impossibile cercare su YouTube.",
              );
            }
          } else {
            await Future.delayed(Duration(milliseconds: 500 * attempt));
            if (!mounted) return;
          }
        }
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _selectVideo(Video video) async {
    if (video.duration != null &&
        video.duration! > const Duration(minutes: 5)) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Canzone lunga'),
          content: const Text(
            'La canzone è più lunga di 5 minuti. Vuoi aggiungerla comunque?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sì'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }

    Navigator.pop(
      context,
      PlaylistItem(
        participant: widget.participantName,
        url: video.url,
        videoId: video.id.value,
        thumbnailUrl: video.thumbnails.mediumResUrl,
      ),
    );
  }

  Future<void> _openMoreResults() async {
    final video = await Navigator.of(context).push<Video>(
      MaterialPageRoute(
        builder: (context) => YoutubeWebSearchPage(
          query: _lastSearchQuery,
          yt: _yt,
          themeData: widget.themeData,
        ),
      ),
    );
    if (!mounted || video == null) return;
    await _selectVideo(video);
  }

  Future<void> _openLocalFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final selectedFile = result.files.single;
      final sourcePath = selectedFile.path;
      if (sourcePath == null) {
        await _showErrorDialog(
          'File non accessibile',
          'Non è stato possibile leggere il file selezionato.',
        );
        return;
      }

      const videoExtensions = {
        'mp4',
        'm4v',
        'mov',
        'avi',
        'mkv',
        'webm',
        '3gp',
      };
      const audioExtensions = {
        'mp3',
        'm4a',
        'aac',
        'wav',
        'ogg',
        'opus',
        'flac',
        'wma',
      };
      final extension = selectedFile.extension?.toLowerCase() ?? '';
      final isLocalVideo = videoExtensions.contains(extension);
      if (!isLocalVideo && !audioExtensions.contains(extension)) {
        await _showErrorDialog(
          'Formato non supportato',
          'Scegli un file audio o video in un formato supportato.',
        );
        return;
      }

      final mediaDirectory = Directory(
        '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}RadioBrongMedia',
      );
      await mediaDirectory.create(recursive: true);
      final destination = File(
        '${mediaDirectory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      await File(sourcePath).copy(destination.path);
      if (!mounted) return;

      Navigator.pop(
        context,
        PlaylistItem(
          participant: widget.participantName,
          url: '',
          localPath: destination.path,
          localTitle: selectedFile.name,
          isLocalVideo: isLocalVideo,
        ),
      );
    } catch (error) {
      debugPrint('Impossibile aprire il file locale: $error');
      if (mounted) {
        await _showErrorDialog(
          'Impossibile aprire il file',
          'Si è verificato un errore durante il caricamento del file.',
        );
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
          TextButton(
            child: const Text("Ok"),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _suggestionDebounce?.cancel();
    _yt.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.themeData.colorScheme;
    final screenSize = MediaQuery.sizeOf(context);
    final compact = screenSize.height < 500;
    return PopScope<PlaylistItem>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(PlaylistItem.back(widget.participantName));
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          backgroundColor: colorScheme.surface,
          elevation: 0,
          automaticallyImplyLeading: false,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(
              context,
            ).pop(PlaylistItem.back(widget.participantName)),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'Turno di ${widget.participantName}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Cerca una canzone',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 13,
                ),
              ),
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
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Padding(
                padding: EdgeInsets.all(compact ? 8 : 16),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Cerca o incolla link',
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                ),
                                border: InputBorder.none,
                              ),
                              onChanged: _onQueryChanged,
                              onSubmitted: _search,
                            ),
                          ),
                          IconButton(
                            onPressed: () => _search(_controller.text),
                            icon: Icon(
                              Icons.search,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_suggestions.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: compact ? 112 : 260,
                        ),
                        child: SingleChildScrollView(
                          child: Container(
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                              color: colorScheme.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.08),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: _suggestions.map((suggestion) {
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    Icons.search,
                                    color: Colors.white.withOpacity(0.65),
                                  ),
                                  title: Text(
                                    suggestion,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  onTap: () {
                                    _controller.text = suggestion;
                                    _controller.selection =
                                        TextSelection.collapsed(
                                          offset: suggestion.length,
                                        );
                                    _search(suggestion);
                                  },
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                    SizedBox(height: compact ? 4 : 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Risultati',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.85),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _openLocalFile,
                          icon: Icon(
                            Icons.folder_open,
                            color: colorScheme.primary,
                          ),
                          label: Text(
                            'Apri file locale',
                            style: TextStyle(color: colorScheme.primary),
                          ),
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.05),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: compact ? 4 : 10),
                    Expanded(
                      child: _isSearching
                          ? const Center(child: CircularProgressIndicator())
                          : _results.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _lastSearchQuery.isEmpty
                                        ? 'Nessun risultato. Scrivi qualcosa sopra per cercare.'
                                        : 'Nessun risultato per "$_lastSearchQuery". Vuoi cercarlo su YouTube?',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                    ),
                                  ),
                                  if (_lastSearchQuery.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    OutlinedButton.icon(
                                      onPressed: _openMoreResults,
                                      icon: Icon(
                                        Icons.open_in_browser,
                                        color: colorScheme.primary,
                                      ),
                                      label: Text(
                                        'Cerca su YouTube',
                                        style: TextStyle(
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: Colors.white
                                            .withOpacity(0.05),
                                        side: BorderSide(
                                          color: colorScheme.primary
                                              .withOpacity(0.5),
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            )
                          : Column(
                              children: [
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: _results.length,
                                    separatorBuilder: (context, index) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (context, index) {
                                      var video = _results[index];
                                      return Material(
                                        color: colorScheme.surface,
                                        borderRadius: BorderRadius.circular(18),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          onTap: () async {
                                            await _selectVideo(video);
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 14,
                                            ),
                                            child: Row(
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  child: Image.network(
                                                    video.thumbnails.lowResUrl,
                                                    width: 82,
                                                    height: 58,
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        video.title,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 6),
                                                      Text(
                                                        video.duration
                                                                ?.toString()
                                                                .split('.')
                                                                .first ??
                                                            '??:??',
                                                        style: TextStyle(
                                                          color: Colors.white
                                                              .withOpacity(0.7),
                                                          fontSize: 13,
                                                        ),
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
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: _openMoreResults,
                                    icon: Icon(
                                      Icons.open_in_browser,
                                      color: colorScheme.primary,
                                    ),
                                    label: Text(
                                      'Mostra altri risultati',
                                      style: TextStyle(
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor: Colors.white.withOpacity(
                                        0.05,
                                      ),
                                      side: BorderSide(
                                        color: colorScheme.primary.withOpacity(
                                          0.5,
                                        ),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class YoutubeWebSearchPage extends StatefulWidget {
  final String query;
  final YoutubeExplode yt;
  final ThemeData themeData;

  const YoutubeWebSearchPage({
    super.key,
    required this.query,
    required this.yt,
    required this.themeData,
  });

  @override
  State<YoutubeWebSearchPage> createState() => _YoutubeWebSearchPageState();
}

class _YoutubeWebSearchPageState extends State<YoutubeWebSearchPage> {
  late final WebViewController _webViewController;
  bool _isSelectingVideo = false;

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'YouTubeVideoSelection',
        onMessageReceived: (message) {
          _selectVideo(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _installVideoSelectionHandler(),
          onNavigationRequest: (request) {
            final videoId = _videoIdFromUrl(request.url);
            if (videoId != null) {
              _selectVideo(videoId);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(
        Uri.https('www.youtube.com', '/results', {
          'search_query': widget.query,
        }),
      );
  }

  Future<void> _installVideoSelectionHandler() async {
    try {
      await _webViewController.runJavaScript(r'''
        (function() {
          if (window._radioVideoSelectionInstalled) return;
          window._radioVideoSelectionInstalled = true;
          document.addEventListener('click', function(event) {
            for (const element of event.composedPath()) {
              if (!element || !element.href) continue;
              let url;
              try {
                url = new URL(element.href, window.location.href);
              } catch (_) {
                continue;
              }
              const host = url.hostname.toLowerCase();
              if (!['youtube.com', 'www.youtube.com', 'm.youtube.com',
                    'youtu.be', 'www.youtube-nocookie.com'].includes(host)) {
                continue;
              }
              let videoId = null;
              if (host.endsWith('youtu.be')) {
                videoId = url.pathname.split('/').filter(Boolean)[0];
              } else if (url.pathname === '/watch') {
                videoId = url.searchParams.get('v');
              } else if (/^\/(shorts|live|embed)\//.test(url.pathname)) {
                videoId = url.pathname.split('/')[2];
              }
              if (!videoId) continue;
              event.preventDefault();
              event.stopImmediatePropagation();
              YouTubeVideoSelection.postMessage(videoId);
              return;
            }
          }, true);
        })();
      ''');
    } catch (error) {
      debugPrint('Impossibile inizializzare la selezione YouTube: $error');
    }
  }

  String? _videoIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host != 'youtube.com' &&
        host != 'www.youtube.com' &&
        host != 'm.youtube.com' &&
        host != 'youtu.be' &&
        host != 'www.youtube-nocookie.com') {
      return null;
    }
    if (host.endsWith('youtu.be')) {
      return uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    }
    if (uri.path == '/watch') return uri.queryParameters['v'];
    if (uri.pathSegments.length >= 2 &&
        const {'shorts', 'live', 'embed'}.contains(uri.pathSegments.first)) {
      return uri.pathSegments[1];
    }
    return null;
  }

  Future<void> _selectVideo(String videoId) async {
    if (_isSelectingVideo) return;
    setState(() => _isSelectingVideo = true);
    try {
      final video = await widget.yt.videos.get(videoId);
      if (!mounted) return;
      Navigator.pop(context, video);
    } catch (error) {
      debugPrint('Impossibile recuperare il video selezionato: $error');
      if (!mounted) return;
      setState(() => _isSelectingVideo = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Video non disponibile'),
          content: const Text(
            'Impossibile recuperare i dettagli del video selezionato.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Ok'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.themeData.colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        title: const Text('Altri risultati YouTube'),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _webViewController),
          if (_isSelectingVideo)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
