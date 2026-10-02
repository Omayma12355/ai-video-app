import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await MobileAds.instance.initialize();

  runApp(const AIVideoApp());
}

class AIVideoApp extends StatelessWidget {
  const AIVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Video',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF09090B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B5CF6),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int dailyFreeCredits = 2;

  // Google test rewarded ad unit.
  // Replace this with your real AdMob rewarded ad unit before release.
  static const String rewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917';

  // Replace with your own secure backend.
  static const String apiUrl =
      'https://YOUR-BACKEND.com/api/generate-video';

  final TextEditingController _promptController = TextEditingController();

  int credits = dailyFreeCredits;
  String? lastResetDate;

  RewardedAd? _rewardedAd;
  bool _isLoadingAd = false;
  bool _isGenerating = false;

  String? generatedVideoUrl;

  @override
  void initState() {
    super.initState();

    _loadCredits();
    _loadRewardedAd();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _rewardedAd?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------
  // DAILY CREDIT SYSTEM
  // ------------------------------------------------------------

  Future<void> _loadCredits() async {
    final prefs = await SharedPreferences.getInstance();

    final today = _todayKey();
    final savedDate = prefs.getString('credit_date');

    if (savedDate != today) {
      await prefs.setString('credit_date', today);
      await prefs.setInt('credits', dailyFreeCredits);

      setState(() {
        credits = dailyFreeCredits;
        lastResetDate = today;
      });
    } else {
      setState(() {
        credits = prefs.getInt('credits') ?? dailyFreeCredits;
        lastResetDate = savedDate;
      });
    }
  }

  String _todayKey() {
    final now = DateTime.now();

    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _saveCredits() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setInt('credits', credits);
    await prefs.setString('credit_date', _todayKey());
  }

  Future<bool> _consumeCredit() async {
    if (credits <= 0) {
      return false;
    }

    setState(() {
      credits--;
    });

    await _saveCredits();

    return true;
  }

  // ------------------------------------------------------------
  // REWARDED ADS
  // ------------------------------------------------------------

  void _loadRewardedAd() {
    if (_isLoadingAd) return;

    _isLoadingAd = true;

    RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          _isLoadingAd = false;

          _rewardedAd = ad;

          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (Ad ad) {
              ad.dispose();
              _rewardedAd = null;

              _loadRewardedAd();
            },
            onAdFailedToShowFullScreenContent: (Ad ad, AdError error) {
              ad.dispose();
              _rewardedAd = null;

              _loadRewardedAd();
            },
          );

          if (mounted) {
            setState(() {});
          }
        },
        onAdFailedToLoad: (LoadAdError error) {
          _isLoadingAd = false;
          _rewardedAd = null;

          debugPrint('Rewarded ad failed: $error');
        },
      ),
    );
  }

  void _watchAdForCredit() {
    final ad = _rewardedAd;

    if (ad == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The reward ad is not ready yet. Please try again.',
          ),
        ),
      );

      _loadRewardedAd();
      return;
    }

    ad.show(
      onUserEarnedReward: (
        AdWithoutView ad,
        RewardItem rewardItem,
      ) async {
        setState(() {
          credits++;
        });

        await _saveCredits();

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('+1 credit added!'),
          ),
        );
      },
    );

    _rewardedAd = null;
  }

  // ------------------------------------------------------------
  // VIDEO GENERATION
  // ------------------------------------------------------------

  Future<void> _generateVideo() async {
    final prompt = _promptController.text.trim();

    if (prompt.isEmpty) {
      _showMessage('Enter a video prompt first.');
      return;
    }

    if (credits <= 0) {
      _showMessage('You have no credits left. Watch an ad to get +1.');
      return;
    }

    final consumed = await _consumeCredit();

    if (!consumed) return;

    setState(() {
      _isGenerating = true;
      generatedVideoUrl = null;
    });

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'prompt': prompt,
          'duration': 8,
        }),
      );

      if (response.statusCode != 200 &&
          response.statusCode != 201) {
        throw Exception(
          'Server error: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      final videoUrl = data['videoUrl'];

      if (videoUrl == null || videoUrl.toString().isEmpty) {
        throw Exception('No video URL returned.');
      }

      setState(() {
        generatedVideoUrl = videoUrl.toString();
      });
    } catch (e) {
      // Return the credit if generation failed.
      setState(() {
        credits++;
      });

      await _saveCredits();

      _showMessage(
        'Generation failed. Your credit has been returned.',
      );

      debugPrint('Generation error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'AI Video',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          _creditBadge(),
          const SizedBox(width: 16),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            20,
            10,
            20,
            30,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heroSection(),

              const SizedBox(height: 28),

              _promptSection(),

              const SizedBox(height: 20),

              _generateButton(),

              const SizedBox(height: 25),

              if (credits <= 0) _rewardCard(),

              if (_isGenerating) ...[
                const SizedBox(height: 20),
                _generatingCard(),
              ],

              if (generatedVideoUrl != null &&
                  !_isGenerating) ...[
                const SizedBox(height: 20),
                VideoPreview(
                  url: generatedVideoUrl!,
                ),
              ],

              const SizedBox(height: 30),

              _tipsSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _creditBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF18181B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(.08),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.bolt_rounded,
            size: 18,
            color: Color(0xFFA78BFA),
          ),
          const SizedBox(width: 5),
          Text(
            '$credits',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 55,
          height: 55,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              colors: [
                Color(0xFF8B5CF6),
                Color(0xFFEC4899),
              ],
            ),
          ),
          child: const Icon(
            Icons.auto_awesome,
            color: Colors.white,
            size: 28,
          ),
        ),

        const SizedBox(height: 18),

        const Text(
          'Create AI Videos',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          'Turn your ideas into stunning 8-second videos.',
          style: TextStyle(
            color: Colors.white.withOpacity(.55),
            fontSize: 16,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _promptSection() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF131316),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.white.withOpacity(.07),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Describe your video',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),

            const SizedBox(height: 12),

            TextField(
              controller: _promptController,
              maxLines: 6,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
              ),
              decoration: InputDecoration(
                hintText:
                    'Example: A cute white kitten running through a magical flower garden at sunset...',
                hintStyle: TextStyle(
                  color: Colors.white.withOpacity(.28),
                ),
                border: InputBorder.none,
              ),
            ),

            const Divider(
              color: Color(0xFF27272A),
            ),

            Row(
              children: [
                const Icon(
                  Icons.timer_outlined,
                  size: 18,
                  color: Colors.white54,
                ),
                const SizedBox(width: 7),
                const Text(
                  '8 seconds',
                  style: TextStyle(
                    color: Colors.white60,
                  ),
                ),
                const Spacer(),
                Text(
                  '1 credit',
                  style: TextStyle(
                    color: const Color(0xFFA78BFA),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _generateButton() {
    final disabled =
        _isGenerating || credits <= 0;

    return SizedBox(
      width: double.infinity,
      height: 58,
      child: ElevatedButton(
        onPressed: disabled ? null : _generateVideo,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B5CF6),
          disabledBackgroundColor: const Color(0xFF29292F),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: _isGenerating
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Creating video...',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.auto_awesome),
                  SizedBox(width: 10),
                  Text(
                    'Generate Video',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _rewardCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF17131F),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF8B5CF6).withOpacity(.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.play_circle_outline_rounded,
                  color: Color(0xFFA78BFA),
                ),
              ),

              const SizedBox(width: 12),

              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Out of credits',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Watch a short ad to get 1 extra credit.',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _watchAdForCredit,
              icon: const Icon(
                Icons.play_arrow_rounded,
              ),
              label: const Text(
                'Watch Ad +1 Credit',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: const Color(0xFF8B5CF6)
                      .withOpacity(.6),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _generatingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF131316),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          const SizedBox(
            width: 45,
            height: 45,
            child: CircularProgressIndicator(
              strokeWidth: 3,
            ),
          ),

          const SizedBox(height: 18),

          const Text(
            'Creating your video',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 17,
            ),
          ),

          const SizedBox(height: 7),

          Text(
            'AI is turning your prompt into an 8-second video...',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(.5),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tipsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Prompt tips',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 12),

        _tip(
          Icons.movie_creation_outlined,
          'Describe the subject and action',
        ),

        _tip(
          Icons.wb_sunny_outlined,
          'Add lighting and atmosphere',
        ),

        _tip(
          Icons.camera_alt_outlined,
          'Mention the camera style',
        ),
      ],
    );
  }

  Widget _tip(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            icon,
            size: 19,
            color: const Color(0xFFA78BFA),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white60,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// VIDEO PREVIEW
// ------------------------------------------------------------

class VideoPreview extends StatefulWidget {
  final String url;

  const VideoPreview({
    super.key,
    required this.url,
  });

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  VideoPlayerController? controller;
  bool initialized = false;

  @override
  void initState() {
    super.initState();

    controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
    );

    controller!.initialize().then((_) {
      if (!mounted) return;

      setState(() {
        initialized = true;
      });
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized || controller == null) {
      return Container(
        height: 400,
        decoration: BoxDecoration(
          color: const Color(0xFF131316),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: controller!.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller!),

            GestureDetector(
              onTap: () {
                setState(() {
                  if (controller!.value.isPlaying) {
                    controller!.pause();
                  } else {
                    controller!.play();
                  }
                });
              },
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.6),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  controller!.value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                  size: 34,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}