import 'dart:convert';

// ---------------------------------------------------------------------------
// Story manifest — lists available stories from assets/stories/manifest.json
// ---------------------------------------------------------------------------

class StoryEntry {
  final String id;
  final String title;
  final String language;
  final String assetPath;

  const StoryEntry({
    required this.id,
    required this.title,
    required this.language,
    required this.assetPath,
  });

  factory StoryEntry.fromJson(Map<String, dynamic> json) {
    return StoryEntry(
      id: json['id'] as String,
      title: json['title'] as String,
      language: json['language'] as String? ?? 'en',
      assetPath: json['asset_path'] as String,
    );
  }
}

class StoryManifest {
  final List<StoryEntry> stories;

  const StoryManifest({required this.stories});

  factory StoryManifest.fromJson(Map<String, dynamic> json) {
    return StoryManifest(
      stories: (json['stories'] as List)
          .map((e) => StoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static StoryManifest fromJsonString(String source) =>
      StoryManifest.fromJson(jsonDecode(source) as Map<String, dynamic>);
}

// ---------------------------------------------------------------------------
// Top-level story container
// ---------------------------------------------------------------------------

class StoryData {
  final BookInfo book;
  final PageOrdering pageOrdering;
  final List<StoryPage> pages;
  final List<Scene> sceneGraph;

  const StoryData({
    required this.book,
    required this.pageOrdering,
    required this.pages,
    required this.sceneGraph,
  });

  /// Convenience getter — returns detected_title or a fallback.
  String get title => book.detectedTitle ?? 'Untitled';

  factory StoryData.fromJson(Map<String, dynamic> json) {
    return StoryData(
      book: BookInfo.fromJson(json['book'] as Map<String, dynamic>),
      pageOrdering: PageOrdering.fromJson(
          json['page_ordering'] as Map<String, dynamic>),
      pages: (json['pages'] as List)
          .map((e) => StoryPage.fromJson(e as Map<String, dynamic>))
          .toList(),
      sceneGraph: (json['scene_graph'] as List)
          .map((e) => Scene.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static StoryData fromJsonString(String source) =>
      StoryData.fromJson(jsonDecode(source) as Map<String, dynamic>);
}

// ---------------------------------------------------------------------------
// Book metadata
// ---------------------------------------------------------------------------

class BookInfo {
  final String? detectedTitle;
  final String language;
  final double analysisConfidence;

  const BookInfo({
    this.detectedTitle,
    required this.language,
    required this.analysisConfidence,
  });

  factory BookInfo.fromJson(Map<String, dynamic> json) {
    return BookInfo(
      detectedTitle: json['detected_title'] as String?,
      language: json['language'] as String? ?? 'en',
      analysisConfidence:
          (json['analysis_confidence'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class PageOrdering {
  final String orderingMethod;
  final double confidence;

  const PageOrdering({
    required this.orderingMethod,
    required this.confidence,
  });

  factory PageOrdering.fromJson(Map<String, dynamic> json) {
    return PageOrdering(
      orderingMethod: json['ordering_method'] as String? ?? 'page_numbers',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

// ---------------------------------------------------------------------------
// A single page of narrative text
// ---------------------------------------------------------------------------

class StoryPage {
  final String pageId;
  final int pageNumber;
  final int orderIndex;
  final double orderConfidence;
  final String fullText;
  final String primarySceneHint;
  final String dominantVisual;
  final String mood;

  const StoryPage({
    required this.pageId,
    required this.pageNumber,
    required this.orderIndex,
    required this.orderConfidence,
    required this.fullText,
    required this.primarySceneHint,
    required this.dominantVisual,
    required this.mood,
  });

  factory StoryPage.fromJson(Map<String, dynamic> json) {
    return StoryPage(
      pageId: json['page_id'] as String? ?? 'page_${json['page_number']}',
      pageNumber: json['page_number'] as int,
      orderIndex: json['order_index'] as int? ?? json['page_number'] as int,
      orderConfidence:
          (json['order_confidence'] as num?)?.toDouble() ?? 1.0,
      fullText: json['full_text'] as String,
      primarySceneHint: json['primary_scene_hint'] as String? ?? '',
      dominantVisual: json['dominant_visual'] as String? ?? '',
      mood: json['mood'] as String? ?? 'calm',
    );
  }
}

// ---------------------------------------------------------------------------
// A scene grouping pages with audio metadata
// ---------------------------------------------------------------------------

class Scene {
  final String sceneId;
  final String sceneSummary;
  final String sceneType;
  final String sceneMood;
  final String sceneEnergy;
  final String narrativePhase;
  final int sceneDurationEstimateSeconds;
  final List<int> pages;
  final SceneActivation sceneActivation;
  final SceneTransition sceneTransition;
  final String likelyNextScene;
  final SceneAudio sceneAudio;
  final List<AudioOpportunity> audioOpportunities;

  const Scene({
    required this.sceneId,
    required this.sceneSummary,
    required this.sceneType,
    required this.sceneMood,
    required this.sceneEnergy,
    required this.narrativePhase,
    required this.sceneDurationEstimateSeconds,
    required this.pages,
    required this.sceneActivation,
    required this.sceneTransition,
    required this.likelyNextScene,
    required this.sceneAudio,
    required this.audioOpportunities,
  });

  factory Scene.fromJson(Map<String, dynamic> json) {
    return Scene(
      sceneId: json['scene_id'] as String,
      sceneSummary: json['scene_summary'] as String,
      sceneType: json['scene_type'] as String? ?? 'other',
      sceneMood: json['scene_mood'] as String,
      sceneEnergy: json['scene_energy'] as String,
      narrativePhase: json['narrative_phase'] as String? ?? 'build_up',
      sceneDurationEstimateSeconds:
          json['scene_duration_estimate_seconds'] as int? ?? 60,
      pages: (json['pages'] as List).map((e) => e as int).toList(),
      sceneActivation: SceneActivation.fromJson(
          json['scene_activation'] as Map<String, dynamic>),
      sceneTransition: SceneTransition.fromJson(
          json['scene_transition'] as Map<String, dynamic>),
      likelyNextScene: json['likely_next_scene'] as String? ?? 'none',
      sceneAudio:
          SceneAudio.fromJson(json['scene_audio'] as Map<String, dynamic>),
      audioOpportunities: (json['audio_opportunities'] as List)
          .map((e) => AudioOpportunity.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Scene activation / transition metadata
// ---------------------------------------------------------------------------

class SceneActivation {
  final String activationMode;
  final double activationConfidenceThreshold;
  final String scenePersistence;
  final List<CueKeyword> entryCues;
  final List<CueKeyword> exitCues;

  const SceneActivation({
    required this.activationMode,
    required this.activationConfidenceThreshold,
    required this.scenePersistence,
    this.entryCues = const [],
    this.exitCues = const [],
  });

  factory SceneActivation.fromJson(Map<String, dynamic> json) {
    return SceneActivation(
      activationMode: json['activation_mode'] as String? ?? 'manual',
      activationConfidenceThreshold:
          (json['activation_confidence_threshold'] as num?)?.toDouble() ?? 0.6,
      scenePersistence:
          json['scene_persistence'] as String? ?? 'until_next_scene',
      entryCues: (json['entry_cues'] as List?)
              ?.map((e) => CueKeyword.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      exitCues: (json['exit_cues'] as List?)
              ?.map((e) => CueKeyword.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

class CueKeyword {
  final List<String> primaryKeywords;
  final List<String> secondaryKeywords;
  final String semanticIntent;

  const CueKeyword({
    this.primaryKeywords = const [],
    this.secondaryKeywords = const [],
    this.semanticIntent = '',
  });

  factory CueKeyword.fromJson(Map<String, dynamic> json) {
    // exit_cues use "keywords" (flat list), entry_cues use "primary_keywords".
    // Normalise both into primaryKeywords so the matcher always has data.
    final primary = (json['primary_keywords'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .toList() ??
        (json['keywords'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .toList() ??
        [];
    final secondary = (json['secondary_keywords'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .toList() ??
        [];
    return CueKeyword(
      primaryKeywords: primary,
      secondaryKeywords: secondary,
      semanticIntent: json['semantic_intent'] as String? ?? '',
    );
  }
}

class SceneTransition {
  final String nextSceneId;
  final String transitionStyle;
  final String audioContinuity;
  final int transitionDurationSeconds;

  const SceneTransition({
    required this.nextSceneId,
    required this.transitionStyle,
    required this.audioContinuity,
    required this.transitionDurationSeconds,
  });

  factory SceneTransition.fromJson(Map<String, dynamic> json) {
    return SceneTransition(
      nextSceneId: json['next_scene_id'] as String? ?? 'none',
      transitionStyle: json['transition_style'] as String? ?? 'crossfade',
      audioContinuity: json['audio_continuity'] as String? ?? 'continue',
      transitionDurationSeconds:
          json['transition_duration_seconds'] as int? ?? 2,
    );
  }
}

// ---------------------------------------------------------------------------
// Audio metadata for a scene
// ---------------------------------------------------------------------------

class SceneAudio {
  final PrimaryAmbience primaryAmbience;
  final List<SecondaryLayer> secondaryLayers;
  final MusicLayer? musicLayer;

  const SceneAudio({
    required this.primaryAmbience,
    required this.secondaryLayers,
    this.musicLayer,
  });

  factory SceneAudio.fromJson(Map<String, dynamic> json) {
    return SceneAudio(
      primaryAmbience: PrimaryAmbience.fromJson(
          json['primary_ambience'] as Map<String, dynamic>),
      secondaryLayers: (json['secondary_layers'] as List? ?? [])
          .map((e) => SecondaryLayer.fromJson(e as Map<String, dynamic>))
          .toList(),
      musicLayer: json['music_layer'] != null
          ? MusicLayer.fromJson(json['music_layer'] as Map<String, dynamic>)
          : null,
    );
  }
}

class PrimaryAmbience {
  final SoundProfile soundProfile;

  const PrimaryAmbience({required this.soundProfile});

  factory PrimaryAmbience.fromJson(Map<String, dynamic> json) {
    return PrimaryAmbience(
      soundProfile: SoundProfile.fromJson(
          json['sound_profile'] as Map<String, dynamic>),
    );
  }
}

class SoundProfile {
  final String primarySound;
  final String variant;
  final String intensity;
  final String texture;
  final String playStyle;

  const SoundProfile({
    required this.primarySound,
    required this.variant,
    required this.intensity,
    required this.texture,
    required this.playStyle,
  });

  factory SoundProfile.fromJson(Map<String, dynamic> json) {
    return SoundProfile(
      primarySound: json['primary_sound'] as String,
      variant: json['variant'] as String,
      intensity: json['intensity'] as String,
      texture: json['texture'] as String,
      playStyle: json['play_style'] as String? ?? 'loop',
    );
  }

  /// Builds the ElevenLabs prompt string for ambience generation.
  String buildAmbiencePrompt({SecondaryLayer? secondary}) {
    final base = '$variant $primarySound background ambience feeling $texture, '
        'continuous seamless ambient audio loop';
    if (secondary == null) return base;
    final sec = secondary.soundProfile;
    return '${sec.variant} ${sec.primarySound} and $variant $primarySound '
        'background ambience feeling $texture, continuous seamless ambient audio loop';
  }
}

/// A secondary ambience layer — now wraps a full [SoundProfile].
class SecondaryLayer {
  final SoundProfile soundProfile;

  const SecondaryLayer({required this.soundProfile});

  factory SecondaryLayer.fromJson(Map<String, dynamic> json) {
    return SecondaryLayer(
      soundProfile: SoundProfile.fromJson(
          json['sound_profile'] as Map<String, dynamic>),
    );
  }
}

class MusicLayer {
  final bool enabled;
  final String musicTheme;
  final String intensity;

  const MusicLayer({
    required this.enabled,
    required this.musicTheme,
    required this.intensity,
  });

  factory MusicLayer.fromJson(Map<String, dynamic> json) {
    return MusicLayer(
      enabled: json['enabled'] as bool? ?? false,
      musicTheme: json['music_theme'] as String? ?? 'calm',
      intensity: json['intensity'] as String? ?? 'low',
    );
  }
}

// ---------------------------------------------------------------------------
// SFX trigger embedded in story text
// ---------------------------------------------------------------------------

class AudioOpportunity {
  final String id;
  final String layerRole;
  final String source;
  final TriggerAnchor triggerAnchor;
  final String eventSummary;
  final String soundCategory;
  final SoundProfile soundProfile;
  final String playbackType;
  final int importance;
  final double confidence;
  final String mixLevel;
  final String emotionalTone;
  final bool triggerOncePerScene;
  final int triggerCooldownSeconds;
  final List<String> triggerPrimaryKeywords;
  final List<String> triggerSecondaryKeywords;

  const AudioOpportunity({
    required this.id,
    required this.layerRole,
    required this.source,
    required this.triggerAnchor,
    required this.eventSummary,
    required this.soundCategory,
    required this.soundProfile,
    required this.playbackType,
    required this.importance,
    required this.confidence,
    required this.mixLevel,
    required this.emotionalTone,
    required this.triggerOncePerScene,
    required this.triggerCooldownSeconds,
    this.triggerPrimaryKeywords = const [],
    this.triggerSecondaryKeywords = const [],
  });

  factory AudioOpportunity.fromJson(Map<String, dynamic> json) {
    return AudioOpportunity(
      id: json['id'] as String? ?? '',
      layerRole: json['layer_role'] as String? ?? 'event',
      source: json['source'] as String? ?? 'text',
      triggerAnchor: TriggerAnchor.fromJson(
          json['trigger_anchor'] as Map<String, dynamic>),
      eventSummary: json['event_summary'] as String,
      soundCategory: json['sound_category'] as String? ?? 'other',
      soundProfile: SoundProfile.fromJson(
          json['sound_profile'] as Map<String, dynamic>),
      playbackType: json['playback_type'] as String? ?? 'oneshot',
      importance: json['importance'] as int? ?? 1,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
      mixLevel: json['mix_level'] as String? ?? 'medium',
      emotionalTone: json['emotional_tone'] as String? ?? 'calm',
      triggerOncePerScene: json['trigger_once_per_scene'] as bool? ?? false,
      triggerCooldownSeconds:
          json['trigger_cooldown_seconds'] as int? ?? 0,
      triggerPrimaryKeywords: _stringList(
          (json['trigger_structure'] as Map?)?.cast<String, dynamic>()
              ['primary_keywords']),
      triggerSecondaryKeywords: _stringList(
          (json['trigger_structure'] as Map?)?.cast<String, dynamic>()
              ['secondary_keywords']),
    );
  }

  static List<String> _stringList(dynamic raw) {
    if (raw == null) return [];
    return (raw as List).map((e) => e.toString().toLowerCase()).toList();
  }
}

class TriggerAnchor {
  final String type;
  final String value;

  const TriggerAnchor({required this.type, required this.value});

  factory TriggerAnchor.fromJson(Map<String, dynamic> json) {
    return TriggerAnchor(
      type: json['type'] as String? ?? 'phrase',
      value: json['value'] as String,
    );
  }
}
