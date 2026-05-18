#!/usr/bin/env python3
"""Merge audio_runtime_policy + per-scene audio_runtime + mix_profile into story JSON files."""

import json
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Global audio_runtime_policy — same for both stories
# ---------------------------------------------------------------------------
AUDIO_RUNTIME_POLICY = {
    "version": "1.0",
    "global_mixing": {
        "master_headroom_db": -6,
        "default_crossfade_ms": 1500,
        "max_simultaneous_event_layers": 3,
        "prevent_hard_clipping": True,
    },
    "bus_structure": {
        "narration_bus": {"priority": 100, "target_lufs": -16},
        "music_bus": {"priority": 40, "target_lufs": -24},
        "ambience_bus": {"priority": 30, "target_lufs": -28},
        "event_bus": {"priority": 80, "target_lufs": -20},
        "animal_bus": {"priority": 60, "target_lufs": -22},
    },
    "default_ducking_policy": {
        "enabled": True,
        "attack_ms": 120,
        "release_ms": 600,
        "rules": [
            {
                "when_bus_active": "event_bus",
                "duck_targets": [
                    {"bus": "music_bus", "gain_reduction_db": -8},
                    {"bus": "ambience_bus", "gain_reduction_db": -4},
                ],
            },
            {
                "when_bus_active": "narration_bus",
                "duck_targets": [
                    {"bus": "music_bus", "gain_reduction_db": -6},
                ],
            },
        ],
    },
}

# ---------------------------------------------------------------------------
# Per-scene audio_runtime overrides keyed by scene_id
# ---------------------------------------------------------------------------

GINGER_SCENE_RUNTIME = {
    "scene_intro": {
        "scene_priority": 30,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": False,
        "max_concurrent_one_shots": 1,
        "transition_behavior": {
            "entry_fade_ms": 2000,
            "exit_fade_ms": 2000,
            "preserve_narration": True,
        },
    },
    "scene_mickey_drought": {
        "scene_priority": 50,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": True,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 1800,
            "exit_fade_ms": 2200,
            "preserve_narration": True,
        },
    },
    "scene_journey_leo": {
        "scene_priority": 45,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": False,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 2000,
            "exit_fade_ms": 2000,
            "preserve_narration": True,
        },
    },
    "scene_animal_gathering": {
        "scene_priority": 40,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": False,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 2000,
            "exit_fade_ms": 2500,
            "preserve_narration": True,
        },
    },
    "scene_fire_danger": {
        "scene_priority": 90,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": True,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 2500,
            "exit_fade_ms": 3000,
            "preserve_narration": True,
        },
    },
    "scene_rain_ending": {
        "scene_priority": 40,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": False,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 3000,
            "exit_fade_ms": 4000,
            "preserve_narration": True,
        },
    },
}

WANDERER_SCENE_RUNTIME = {
    "scene_forest": {
        "scene_priority": 35,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": False,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 2000,
            "exit_fade_ms": 2000,
            "preserve_narration": True,
        },
    },
    "scene_village": {
        "scene_priority": 40,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": False,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 1800,
            "exit_fade_ms": 2200,
            "preserve_narration": True,
        },
    },
    "scene_storm": {
        "scene_priority": 85,
        "allow_music": True,
        "allow_ambience": True,
        "dynamic_ducking": True,
        "max_concurrent_one_shots": 2,
        "transition_behavior": {
            "entry_fade_ms": 2500,
            "exit_fade_ms": 3000,
            "preserve_narration": True,
        },
    },
}

# ---------------------------------------------------------------------------
# Per-audio_opportunity runtime fields keyed by ao id
# ---------------------------------------------------------------------------

GINGER_AO_RUNTIME = {
    "ao_leaves": {
        "bus": "event_bus",
        "priority": 20,
        "exclusive_group": "nature_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
    "ao_mickey_falls": {
        "bus": "event_bus",
        "priority": 70,
        "exclusive_group": "movement_events",
        "interrupt_lower_priority": True,
        "temporary_ducking": {
            "targets": [{"bus": "music_bus", "gain_reduction_db": -5}],
            "attack_ms": 50,
            "release_ms": 500,
        },
    },
    "ao_mickey_eats": {
        "bus": "animal_bus",
        "priority": 40,
        "exclusive_group": "animal_recovery",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
    "ao_leo_wakes": {
        "bus": "animal_bus",
        "priority": 50,
        "exclusive_group": "animal_vocalizations",
        "interrupt_lower_priority": False,
        "temporary_ducking": {
            "targets": [{"bus": "music_bus", "gain_reduction_db": -3}],
            "attack_ms": 80,
            "release_ms": 600,
        },
    },
    "ao_elephant_voice": {
        "bus": "animal_bus",
        "priority": 40,
        "exclusive_group": "animal_vocalizations",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
    "ao_thunder": {
        "bus": "event_bus",
        "priority": 95,
        "exclusive_group": "danger_events",
        "interrupt_lower_priority": True,
        "temporary_ducking": {
            "targets": [
                {"bus": "music_bus", "gain_reduction_db": -12},
                {"bus": "ambience_bus", "gain_reduction_db": -6},
            ],
            "attack_ms": 50,
            "release_ms": 1200,
        },
    },
    "ao_running_hooves": {
        "bus": "animal_bus",
        "priority": 70,
        "exclusive_group": "movement_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {
            "targets": [{"bus": "music_bus", "gain_reduction_db": -4}],
            "attack_ms": 100,
            "release_ms": 800,
        },
    },
    "ao_raindrops": {
        "bus": "event_bus",
        "priority": 80,
        "exclusive_group": "weather_events",
        "interrupt_lower_priority": True,
        "temporary_ducking": {
            "targets": [{"bus": "music_bus", "gain_reduction_db": -5}],
            "attack_ms": 100,
            "release_ms": 1000,
        },
    },
    "ao_happy_animals": {
        "bus": "animal_bus",
        "priority": 50,
        "exclusive_group": "celebration_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
}

WANDERER_AO_RUNTIME = {
    "ao_stream_murmur": {
        "bus": "event_bus",
        "priority": 20,
        "exclusive_group": "nature_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
    "ao_spirit_fish": {
        "bus": "event_bus",
        "priority": 60,
        "exclusive_group": "magic_events",
        "interrupt_lower_priority": True,
        "temporary_ducking": {
            "targets": [{"bus": "music_bus", "gain_reduction_db": -4}],
            "attack_ms": 80,
            "release_ms": 800,
        },
    },
    "ao_blacksmith": {
        "bus": "event_bus",
        "priority": 30,
        "exclusive_group": "craft_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
    "ao_dog_bark": {
        "bus": "animal_bus",
        "priority": 25,
        "exclusive_group": "animal_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
    "ao_lightning": {
        "bus": "event_bus",
        "priority": 95,
        "exclusive_group": "danger_events",
        "interrupt_lower_priority": True,
        "temporary_ducking": {
            "targets": [
                {"bus": "music_bus", "gain_reduction_db": -12},
                {"bus": "ambience_bus", "gain_reduction_db": -6},
            ],
            "attack_ms": 50,
            "release_ms": 1200,
        },
    },
    "ao_hearth": {
        "bus": "ambience_bus",
        "priority": 40,
        "exclusive_group": "comfort_events",
        "interrupt_lower_priority": False,
        "temporary_ducking": {"targets": [], "attack_ms": 0, "release_ms": 0},
    },
}

# ---------------------------------------------------------------------------
# Per-scene mix_profile data for primary_ambience, secondary_layers, music_layer
# ---------------------------------------------------------------------------

def mix_profile(base_gain_db, stereo_width=0.5, ducking_sensitive=True,
                lowpass_hz=None, sidechain_sensitive=False):
    p = {
        "base_gain_db": base_gain_db,
        "stereo_width": stereo_width,
        "ducking_sensitive": ducking_sensitive,
    }
    if lowpass_hz is not None:
        p["lowpass_hz"] = lowpass_hz
    if sidechain_sensitive:
        p["sidechain_sensitive"] = True
    return p


GINGER_SCENE_AUDIO_MIX = {
    "scene_intro": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-24, 0.5)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-28, 0.4)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-28, ducking_sensitive=True)},
    },
    "scene_mickey_drought": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-22, 0.6)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-26, 0.5)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-26, ducking_sensitive=True)},
    },
    "scene_journey_leo": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-22, 0.6)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-26, 0.5)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-26, ducking_sensitive=True)},
    },
    "scene_animal_gathering": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-22, 0.6)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-26, 0.5)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-26, ducking_sensitive=True)},
    },
    "scene_fire_danger": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-18, 0.8, lowpass_hz=12000)},
        "secondary_layers": [{"bus": "event_bus", "mix_profile": mix_profile(-16, sidechain_sensitive=True)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-22, ducking_sensitive=True)},
    },
    "scene_rain_ending": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-20, 0.7)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-24, 0.6)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-24, ducking_sensitive=False)},
    },
}

WANDERER_SCENE_AUDIO_MIX = {
    "scene_forest": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-24, 0.5)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-28, 0.4)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-28, ducking_sensitive=True)},
    },
    "scene_village": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-22, 0.6)},
        "secondary_layers": [{"bus": "ambience_bus", "mix_profile": mix_profile(-26, 0.5)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-26, ducking_sensitive=True)},
    },
    "scene_storm": {
        "primary_ambience": {"bus": "ambience_bus", "mix_profile": mix_profile(-18, 0.8, lowpass_hz=12000)},
        "secondary_layers": [{"bus": "event_bus", "mix_profile": mix_profile(-16, sidechain_sensitive=True)}],
        "music_layer": {"bus": "music_bus", "mix_profile": mix_profile(-22, ducking_sensitive=True)},
    },
}


# ---------------------------------------------------------------------------
# Merge logic
# ---------------------------------------------------------------------------

def merge_story(filepath: str, scene_runtime_map: dict, ao_runtime_map: dict,
                scene_audio_mix_map: dict):
    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    # 1. Insert global audio_runtime_policy
    data["audio_runtime_policy"] = AUDIO_RUNTIME_POLICY

    # 2. Enrich each scene
    for scene in data.get("scene_graph", []):
        sid = scene["scene_id"]

        # 2a. audio_runtime
        if sid in scene_runtime_map:
            scene["audio_runtime"] = scene_runtime_map[sid]

        # 2b. Enrich scene_audio with bus + mix_profile
        sa = scene.get("scene_audio", {})
        mix_info = scene_audio_mix_map.get(sid, {})

        # primary_ambience
        pa = sa.get("primary_ambience", {})
        pa_mix = mix_info.get("primary_ambience", {})
        if "bus" in pa_mix:
            pa["bus"] = pa_mix["bus"]
        if "mix_profile" in pa_mix:
            pa["mix_profile"] = pa_mix["mix_profile"]
        sa["primary_ambience"] = pa

        # secondary_layers
        sl_list = sa.get("secondary_layers", [])
        sl_mix_list = mix_info.get("secondary_layers", [])
        for i, sl in enumerate(sl_list):
            if i < len(sl_mix_list):
                sl_mix = sl_mix_list[i]
                if "bus" in sl_mix:
                    sl["bus"] = sl_mix["bus"]
                if "mix_profile" in sl_mix:
                    sl["mix_profile"] = sl_mix["mix_profile"]
        sa["secondary_layers"] = sl_list

        # music_layer
        ml = sa.get("music_layer", {})
        ml_mix = mix_info.get("music_layer", {})
        if "bus" in ml_mix:
            ml["bus"] = ml_mix["bus"]
        if "mix_profile" in ml_mix:
            ml["mix_profile"] = ml_mix["mix_profile"]
        sa["music_layer"] = ml

        scene["scene_audio"] = sa

        # 2c. Enrich audio_opportunities
        for ao in scene.get("audio_opportunities", []):
            ao_id = ao.get("id", "")
            ao_rt = ao_runtime_map.get(ao_id, {})
            for key in ("bus", "priority", "exclusive_group",
                        "interrupt_lower_priority", "temporary_ducking"):
                if key in ao_rt:
                    ao[key] = ao_rt[key]

    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"  ✓ {filepath}")


def main():
    base = Path(__file__).resolve().parent.parent / "assets" / "stories"

    print("Merging audio_runtime_policy into story JSON files…")
    merge_story(
        str(base / "ginger_the_giraffe.json"),
        GINGER_SCENE_RUNTIME,
        GINGER_AO_RUNTIME,
        GINGER_SCENE_AUDIO_MIX,
    )
    merge_story(
        str(base / "the_wanderers_chronicle.json"),
        WANDERER_SCENE_RUNTIME,
        WANDERER_AO_RUNTIME,
        WANDERER_SCENE_AUDIO_MIX,
    )
    print("Done.")


if __name__ == "__main__":
    main()
