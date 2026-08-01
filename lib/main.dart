// ============================================================================
// MELTDOWN — a single-file nuclear plant control room simulator.
// Zero pub dependencies. All gameplay, physics, audio and rendering live here.
// ============================================================================
//
//  WHAT THIS IS
//    A pressurized water reactor you operate by hand. Fission heats fuel, fuel
//    heats pressurised water, that water boils a second loop into steam, steam
//    spins a turbine, and the turbine sells megawatts to the grid. You are paid
//    only for megawatts that actually reach the grid.
//
//  THE CENTRAL PROPERTY: negative temperature feedback. Reactivity falls as the
//    coolant heats, so an unattended plant settles at equilibrium rather than
//    running away. Death is never on a timer — the protection system trips you
//    long before damage, a trip is survivable, and END SHIFT always banks your
//    work safely. Losing the core is something you earn.
//
//  PERFORMANCE
//    Nothing rebuilds per frame. The game loop bumps a ValueNotifier that is
//    handed to every CustomPainter as its `repaint` listenable, so a frame
//    costs paint only — no element walk, no layout. Widgets rebuild solely on
//    discrete events (a switch flipped, a tab changed, an upgrade bought).
//
//  PERSISTENCE (web build)
//    localStorage via dart:js_interop — still no packages. For a native build,
//    replace the three @JS declarations and rawLoad/rawSave/rawWipe with:
//
//      import 'dart:io';
//      String get _p => '${Directory.systemTemp.path}/meltdown_save.json';
//      String? rawLoad() { final f = File(_p);
//        return f.existsSync() ? f.readAsStringSync() : null; }
//      void rawSave(String d) => File(_p).writeAsStringSync(d);
//      void rawWipe() { final f = File(_p); if (f.existsSync()) f.deleteSync(); }
// ============================================================================

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'audio_web.dart' if (dart.library.io) 'audio_io.dart';
import 'speech_web.dart' if (dart.library.io) 'speech_io.dart';
import 'storage_web.dart' if (dart.library.io) 'storage_io.dart';

// Re-exported so tests (and any embedder) can reset the save without needing to
// know which storage backend was selected.
export 'storage_web.dart' if (dart.library.io) 'storage_io.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A control room is a portrait instrument panel; landscape would squash the
  // console into unusable slivers.
  SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: cBg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const ReactorApp());
}

// ===========================================================================
// SECTION 1 — persistence
// ===========================================================================
// The save format is identical on every platform; only the sink differs.
// storage_io.dart writes a JSON file in the app's Documents directory (iOS,
// Android, desktop); storage_web.dart uses localStorage. Both expose exactly
// rawLoad / rawSave / rawWipe, so nothing else in the game knows or cares.

// ===========================================================================
// SECTION 2 — formatting helpers
// ===========================================================================

const List<String> _suffixes = [
  'K', 'M', 'B', 'T', 'Qa', 'Qi', 'Sx', 'Sp', 'Oc', 'No', 'Dc',
];

String fmt(num v) {
  var d = v.toDouble();
  if (!d.isFinite) return '∞';
  if (d < 0) return '-${fmt(-d)}';
  if (d < 1000) {
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
  }
  var i = -1;
  while (d >= 1000 && i < _suffixes.length - 1) {
    d /= 1000;
    i++;
  }
  if (d >= 999.5 && i < _suffixes.length - 1) {
    d /= 1000;
    i++;
  }
  final s = d >= 100
      ? d.toStringAsFixed(0)
      : d >= 10
          ? d.toStringAsFixed(1)
          : d.toStringAsFixed(2);
  return '$s${_suffixes[i]}';
}

String formatDur(double seconds) {
  final s = seconds.floor();
  if (s >= 86400) return '${s ~/ 86400}d ${(s % 86400) ~/ 3600}h';
  if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  if (s >= 60) return '${s ~/ 60}m ${s % 60}s';
  return '${s}s';
}

String mmss(double seconds) {
  if (!seconds.isFinite) return '—';
  final s = seconds.floor();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$sec';
  return '$m:$sec';
}

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
double clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
double lerpD(double a, double b, double t) => a + (b - a) * t;

// ===========================================================================
// SECTION 3 — palette
// ===========================================================================

const cBg = Color(0xFF0B0E13);
const cPanel = Color(0xFF141A22);
const cPanel2 = Color(0xFF1B232E);
const cEdge = Color(0xFF2C3742);
const cInk = Color(0xFFD8E3EE);
const cInkDim = Color(0xFF7C8B9B);
const cInkFaint = Color(0xFF4A5764);
const cGreen = Color(0xFF4BE08A);
const cAmber = Color(0xFFFFB03A);
const cRed = Color(0xFFFF4B3E);
const cBlue = Color(0xFF4FA8FF);
const cCyan = Color(0xFF49DCE8);
const cViolet = Color(0xFFB07BFF);
const cGold = Color(0xFFFFC94D);

// ===========================================================================
// SECTION 4 — sound and touch feedback
// ===========================================================================
// Sound is synthesized live on web (audio_web.dart). On iOS there is no
// dependency-free way to synthesize, so every control also fires a haptic —
// which is the feedback that actually makes a button feel physical in the hand.

class Sfx {
  final AudioEngine _a = AudioEngine();
  final math.Random _rng = math.Random();
  bool muted = false;

  bool get synthesizes => _a.synthesizes;

  void _tone({
    required double f0,
    double? f1,
    String wave = 'square',
    double dur = 0.08,
    double vol = 0.15,
    double delay = 0,
  }) {
    if (muted) return;
    _a.tone(f0: f0, f1: f1, wave: wave, dur: dur, vol: vol, delay: delay);
  }

  void _hiss({
    double dur = 0.2,
    double vol = 0.2,
    String type = 'lowpass',
    double fFrom = 6000,
    double fTo = 500,
    double delay = 0,
  }) {
    if (muted) return;
    _a.noise(
        dur: dur, vol: vol, type: type, fFrom: fFrom, fTo: fTo, delay: delay);
  }

  // Haptics are deliberately not gated on `muted`: muting is about noise, and
  // silencing touch feedback would make the console feel broken.
  void _tapLight() {
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}
  }

  void _tapMedium() {
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  void _tapHeavy() {
    try {
      HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  void _tapSelect() {
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  /// The sound of the console: a heavy industrial switch.
  void clunk([double pitch = 1]) {
    _hiss(dur: 0.035, vol: 0.22, type: 'lowpass', fFrom: 900 * pitch, fTo: 160);
    _tone(f0: 150 * pitch, f1: 60, wave: 'square', dur: 0.05, vol: 0.10);
    _tapMedium();
  }

  /// Release half of a switch throw — lighter than the press.
  void clunkUp([double pitch = 1]) {
    _hiss(dur: 0.028, vol: 0.15, type: 'lowpass', fFrom: 700 * pitch, fTo: 140);
    _tapLight();
  }

  void softClick() {
    _hiss(dur: 0.02, vol: 0.12, type: 'highpass', fFrom: 2000, fTo: 3000);
    _tapSelect();
  }

  void rodStep() {
    _tone(f0: 420, f1: 300, wave: 'square', dur: 0.03, vol: 0.05);
    _hiss(dur: 0.03, vol: 0.07, type: 'bandpass', fFrom: 1200, fTo: 800);
  }

  void pumpStart() {
    _tone(f0: 40, f1: 210, wave: 'sawtooth', dur: 1.4, vol: 0.13);
    _hiss(dur: 1.6, vol: 0.14, type: 'lowpass', fFrom: 200, fTo: 900);
    _tapHeavy();
  }

  void pumpStop() {
    _tone(f0: 210, f1: 35, wave: 'sawtooth', dur: 1.1, vol: 0.11);
    _hiss(dur: 1.2, vol: 0.10, type: 'lowpass', fFrom: 900, fTo: 120);
    _tapMedium();
  }

  void valve() {
    _hiss(dur: 0.5, vol: 0.20, fFrom: 5000, fTo: 300);
    _tapMedium();
  }

  void breaker() {
    _tone(f0: 90, f1: 45, wave: 'square', dur: 0.16, vol: 0.26);
    _hiss(dur: 0.2, vol: 0.24, type: 'lowpass', fFrom: 1600, fTo: 120);
    _tapHeavy();
  }

  void buy() {
    _tone(f0: 520, wave: 'triangle', dur: 0.05, vol: 0.11);
    _tone(f0: 784, wave: 'triangle', dur: 0.09, vol: 0.11, delay: 0.055);
    _tapMedium();
  }

  void deny() {
    _tone(f0: 150, f1: 90, wave: 'square', dur: 0.14, vol: 0.11);
    _tapHeavy();
  }

  /// Annunciator horn — the two-tone blast that means read the tiles.
  void horn() {
    _tone(f0: 440, wave: 'square', dur: 0.30, vol: 0.075);
    _tone(f0: 330, wave: 'square', dur: 0.30, vol: 0.075);
  }

  void criticalHorn() {
    _tone(f0: 620, f1: 480, wave: 'sawtooth', dur: 0.45, vol: 0.10);
    _tone(f0: 310, f1: 240, wave: 'square', dur: 0.45, vol: 0.07);
    _tapLight();
  }

  void scram() {
    _tone(f0: 900, f1: 120, wave: 'sawtooth', dur: 1.1, vol: 0.22);
    _hiss(dur: 1.3, vol: 0.30, fFrom: 5000, fTo: 90);
    _tone(f0: 70, f1: 40, wave: 'sine', dur: 1.6, vol: 0.22, delay: 0.05);
    _tapHeavy();
  }

  void geiger(double intensity) => _hiss(
        dur: 0.012 + _rng.nextDouble() * 0.013,
        vol: 0.03 + 0.09 * intensity,
        type: 'highpass',
        fFrom: 2500,
        fTo: 3500,
      );

  void meltdown() {
    _tone(f0: 150, f1: 27, wave: 'sine', dur: 1.4, vol: 0.5);
    _tone(f0: 95, f1: 33, wave: 'square', dur: 0.7, vol: 0.30, delay: 0.1);
    _hiss(dur: 1.9, vol: 0.55, fFrom: 8500, fTo: 55);
    for (var i = 0; i < 6; i++) {
      _hiss(
        dur: 0.02,
        vol: 0.14,
        type: 'highpass',
        fFrom: 2200,
        fTo: 3200,
        delay: 0.4 + _rng.nextDouble() * 1.3,
      );
    }
    _tapHeavy();
  }

  void powerUp() {
    _tone(f0: 90, f1: 440, wave: 'sawtooth', dur: 0.65, vol: 0.11);
    _hiss(dur: 0.55, vol: 0.07, type: 'highpass', fFrom: 400, fTo: 2000);
    _tapMedium();
  }

  void chime() {
    _tone(f0: 660, wave: 'sine', dur: 0.14, vol: 0.10);
    _tone(f0: 990, wave: 'sine', dur: 0.20, vol: 0.09, delay: 0.10);
    _tapMedium();
  }

  /// A swallow: short wet click, then a warm settle.
  void sip() {
    _hiss(dur: 0.09, vol: 0.13, type: 'bandpass', fFrom: 900, fTo: 420);
    _tone(f0: 240, f1: 380, wave: 'sine', dur: 0.16, vol: 0.09, delay: 0.05);
    _tapLight();
  }

  /// The scream. Detuned formants sliding down over a breathy noise bed —
  /// close enough to a human voice to be wrong, far enough to be unplaceable.
  void scream() {
    final base = 380 + _rng.nextDouble() * 260;
    _tone(f0: base, f1: base * 0.34, wave: 'sawtooth', dur: 1.5, vol: 0.16);
    _tone(
        f0: base * 1.51,
        f1: base * 0.47,
        wave: 'sawtooth',
        dur: 1.4,
        vol: 0.10,
        delay: 0.04);
    _tone(
        f0: base * 2.02,
        f1: base * 0.62,
        wave: 'triangle',
        dur: 1.2,
        vol: 0.06,
        delay: 0.09);
    _hiss(dur: 1.7, vol: 0.13, type: 'bandpass', fFrom: 1800, fTo: 300);
    _tone(f0: 58, f1: 31, wave: 'sine', dur: 2.1, vol: 0.14, delay: 0.2);
    _tapHeavy();
  }
}

// ===========================================================================
// SECTION 5 — upgrades
// ===========================================================================

class ShopItem {
  const ShopItem({
    required this.id,
    required this.name,
    required this.desc,
    required this.glyph,
    required this.panel,
    required this.baseCost,
    required this.growth,
    required this.maxLevel,
    required this.color,
    this.research = false,
  });

  final String id;
  final String name;
  final String desc;
  final String glyph;
  final String panel;
  final double baseCost;
  final double growth;
  final int maxLevel;
  final Color color;
  final bool research;

  double costAt(int level) => baseCost * math.pow(growth, level).toDouble();
}

const List<ShopItem> kShop = [
  ShopItem(
    id: 'rodSpeed',
    name: 'CRDM DRIVE GEARING',
    desc: 'Control rods travel 25% faster.',
    glyph: '↕',
    panel: 'REACTIVITY',
    color: cGreen,
    baseCost: 400,
    growth: 1.8,
    maxLevel: 8,
  ),
  ShopItem(
    id: 'boronRate',
    name: 'CVCS CHARGING PUMP',
    desc: 'Boration and dilution run 30% faster.',
    glyph: '⌬',
    panel: 'REACTIVITY',
    color: cGreen,
    baseCost: 650,
    growth: 1.8,
    maxLevel: 8,
  ),
  ShopItem(
    id: 'rcpLoop',
    name: 'EXTRA COOLANT LOOP',
    desc: 'Commissions another reactor coolant pump.',
    glyph: '⊙',
    panel: 'COOLANT',
    color: cBlue,
    baseCost: 3000,
    growth: 6.0,
    maxLevel: 2,
  ),
  ShopItem(
    id: 'heaterCap',
    name: 'PRESSURIZER HEATER BANK',
    desc: 'Heaters push 15% harder — more pressure authority.',
    glyph: '♨',
    panel: 'COOLANT',
    color: cBlue,
    baseCost: 900,
    growth: 1.9,
    maxLevel: 6,
  ),
  ShopItem(
    id: 'feedCap',
    name: 'FEEDWATER PUMP CAPACITY',
    desc: 'Feed pumps deliver 20% more flow.',
    glyph: '→',
    panel: 'STEAM',
    color: cCyan,
    baseCost: 1200,
    growth: 1.9,
    maxLevel: 6,
  ),
  ShopItem(
    id: 'turbEff',
    name: 'TURBINE BLADE PROFILE',
    desc: 'Converts steam to megawatts 8% more efficiently.',
    glyph: '❋',
    panel: 'STEAM',
    color: cCyan,
    baseCost: 1800,
    growth: 2.0,
    maxLevel: 10,
  ),
  ShopItem(
    id: 'sgCap',
    name: 'STEAM GENERATOR VOLUME',
    desc: 'Bigger water inventory — level drifts 20% slower.',
    glyph: '▤',
    panel: 'STEAM',
    color: cCyan,
    baseCost: 1100,
    growth: 1.9,
    maxLevel: 6,
  ),
  ShopItem(
    id: 'gridPrice',
    name: 'GRID SUPPLY CONTRACT',
    desc: 'Each megawatt sells for 18% more.',
    glyph: '⌁',
    panel: 'ELECTRICAL',
    color: cGold,
    baseCost: 1500,
    growth: 2.1,
    maxLevel: 12,
  ),
  ShopItem(
    id: 'contain',
    name: 'CONTAINMENT LINER',
    desc: 'Core damage accumulates 18% slower.',
    glyph: '⬒',
    panel: 'SAFETY',
    color: cRed,
    baseCost: 2200,
    growth: 2.0,
    maxLevel: 8,
  ),
  ShopItem(
    id: 'scramMargin',
    name: 'PROTECTION SETPOINT TRIM',
    desc: 'Auto-SCRAM trips earlier, leaving more margin.',
    glyph: '▽',
    panel: 'SAFETY',
    color: cRed,
    baseCost: 2600,
    growth: 2.2,
    maxLevel: 5,
  ),
  ShopItem(
    id: 'autoRod',
    name: 'ROD-9 REACTIVITY BOT',
    desc: 'Drives the rod banks to your power setpoint. Unlocks AUTO ROD.',
    glyph: '▣',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 9000,
    growth: 1,
    maxLevel: 1,
  ),
  ShopItem(
    id: 'autoPzr',
    name: 'PZR-4 PRESSURE BOT',
    desc: 'Works the heaters and spray to hold 155 bar. Unlocks AUTO PZR.',
    glyph: '◉',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 12000,
    growth: 1,
    maxLevel: 1,
  ),
  ShopItem(
    id: 'autoTurb',
    name: 'SYNC-3 GRID BOT',
    desc: 'Watches the synchroscope and closes the breaker in phase.',
    glyph: '◐',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 16000,
    growth: 1,
    maxLevel: 1,
  ),
  ShopItem(
    id: 'feedBot',
    name: 'FEED-2 WATER BOT',
    desc: 'Nudges the feed pump to keep steam generator level on 50%.',
    glyph: '≡',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 14000,
    growth: 1,
    maxLevel: 1,
  ),
  ShopItem(
    id: 'watchBot',
    name: 'WATCH-1 ALARM BOT',
    desc: 'Acknowledges the annunciator for you and silences the horn.',
    glyph: '△',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 8000,
    growth: 1,
    maxLevel: 1,
  ),
  ShopItem(
    id: 'baristaBot',
    name: 'BARISTA-B AI',
    desc: 'Serves you a sip from the canteen whenever sanity drops below 35.',
    glyph: '☕',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 20000,
    growth: 1,
    maxLevel: 1,
  ),
  ShopItem(
    id: 'earDefenders',
    name: 'EAR DEFENDERS',
    desc: 'The screaming still happens. It just costs you 40% less sanity.',
    glyph: '∩',
    panel: 'AI CREW',
    color: cViolet,
    baseCost: 6000,
    growth: 2.4,
    maxLevel: 3,
  ),
  // ---- research (◆), permanent -------------------------------------------
  ShopItem(
    id: 'payout',
    name: 'REGULATORY GOODWILL',
    desc: 'All credit income ×1.6.',
    glyph: '◈',
    panel: 'PERMANENT',
    color: cGold,
    baseCost: 3,
    growth: 2,
    maxLevel: 20,
    research: true,
  ),
  ShopItem(
    id: 'uprate',
    name: 'LICENSED POWER UPRATE',
    desc: 'Rated electrical output +12%.',
    glyph: '▲',
    panel: 'PERMANENT',
    color: cGold,
    baseCost: 4,
    growth: 2,
    maxLevel: 15,
    research: true,
  ),
  ShopItem(
    id: 'hotStart',
    name: 'HOT STANDBY HANDOVER',
    desc: 'Start every shift hot, pressurised and critical.',
    glyph: '⏻',
    panel: 'PERMANENT',
    color: cAmber,
    baseCost: 6,
    growth: 1,
    maxLevel: 1,
    research: true,
  ),
  ShopItem(
    id: 'repair',
    name: 'IN-SERVICE FUEL REPAIR',
    desc: 'Core damage slowly self-repairs while conditions are safe.',
    glyph: '✚',
    panel: 'PERMANENT',
    color: cGreen,
    baseCost: 8,
    growth: 2.5,
    maxLevel: 4,
    research: true,
  ),
  ShopItem(
    id: 'dispatch',
    name: 'REMOTE DISPATCH LICENCE',
    desc: 'Earn while away: +30% offline rate and +4h cap.',
    glyph: '⧗',
    panel: 'PERMANENT',
    color: cViolet,
    baseCost: 5,
    growth: 2,
    maxLevel: 8,
    research: true,
  ),
  ShopItem(
    id: 'smartAnn',
    name: 'SMART ANNUNCIATOR',
    desc: 'Alarms acknowledge themselves and clear when conditions return.',
    glyph: '△',
    panel: 'PERMANENT',
    color: cAmber,
    baseCost: 6,
    growth: 1,
    maxLevel: 1,
    research: true,
  ),
];

// ===========================================================================
// SECTION 5b — the canteen: consumables that hold your sanity together
// ===========================================================================
// A shift is long and the building makes noises. Every item is bought with
// uranium between shifts and drunk or eaten during one; a unit contributes a
// number of sips, and each sip restores sanity.

class Consumable {
  const Consumable({
    required this.id,
    required this.name,
    required this.tagline,
    required this.glyph,
    required this.color,
    required this.cost,
    required this.sips,
    required this.perSip,
  });

  final String id;
  final String name;
  final String tagline;
  final String glyph;
  final Color color;
  final double cost; // uranium per unit
  final int sips; // uses per unit
  final double perSip; // sanity restored per use

  double get total => sips * perSip;
}

const List<Consumable> kCanteen = [
  Consumable(
    id: 'coffee',
    name: 'BLACK START',
    tagline: 'Station coffee. Three sips, fifteen each.',
    glyph: '☕',
    color: Color(0xFFC98A4B),
    cost: 50,
    sips: 3,
    perSip: 15,
  ),
  Consumable(
    id: 'cocoa',
    name: 'CONTROL ROD',
    tagline: 'Dense chocolate bar. Snaps into four.',
    glyph: '▮',
    color: Color(0xFF8C6239),
    cost: 70,
    sips: 4,
    perSip: 12,
  ),
  Consumable(
    id: 'energy',
    name: 'COOLANT',
    tagline: 'Cold blue energy drink. Two long pulls.',
    glyph: '⚡',
    color: cCyan,
    cost: 110,
    sips: 2,
    perSip: 22,
  ),
  Consumable(
    id: 'noodles',
    name: 'NIGHT SHIFT',
    tagline: 'Instant noodles at 3am. One good bowl.',
    glyph: '◉',
    color: cAmber,
    cost: 140,
    sips: 1,
    perSip: 38,
  ),
  Consumable(
    id: 'water',
    name: 'HEAVY WATER',
    tagline: 'Just water, honestly. Five steady sips.',
    glyph: '≈',
    color: cBlue,
    cost: 40,
    sips: 5,
    perSip: 8,
  ),
  Consumable(
    id: 'donut',
    name: 'CRITICALITY',
    tagline: 'Glazed ring. Goes prompt in one bite.',
    glyph: '◎',
    color: Color(0xFFFF9BC4),
    cost: 90,
    sips: 2,
    perSip: 18,
  ),
  Consumable(
    id: 'sandwich',
    name: 'CONTAINMENT',
    tagline: 'Sealed triple-decker. Holds everything in.',
    glyph: '▤',
    color: cGreen,
    cost: 160,
    sips: 3,
    perSip: 20,
  ),
  Consumable(
    id: 'ration',
    name: 'DECAY HEAT',
    tagline: 'Emergency ration. Warm, grim, effective.',
    glyph: '◫',
    color: cRed,
    cost: 220,
    sips: 4,
    perSip: 24,
  ),
];

Consumable canteenItem(String id) => kCanteen.firstWhere((e) => e.id == id);

// ===========================================================================
// SECTION 6 — annunciator alarms
// ===========================================================================

enum AlarmState { clear, flashing, acked }

class AlarmDef {
  const AlarmDef(this.id, this.l1, this.l2, this.critical);
  final String id;
  final String l1;
  final String l2;
  final bool critical;
}

const List<AlarmDef> kAlarms = [
  AlarmDef('scram', 'REACTOR', 'TRIP', true),
  AlarmDef('hiflux', 'HI NEUTRON', 'FLUX', true),
  AlarmDef('hifuel', 'HI FUEL', 'TEMP', true),
  AlarmDef('hipress', 'HI RCS', 'PRESSURE', true),
  AlarmDef('lopress', 'LO RCS', 'PRESSURE', false),
  AlarmDef('hitavg', 'HI COOLANT', 'TEMP', true),
  AlarmDef('loflow', 'LO COOLANT', 'FLOW', true),
  AlarmDef('losg', 'LO SG', 'LEVEL', true),
  AlarmDef('hisg', 'HI SG', 'LEVEL', false),
  AlarmDef('lofeed', 'LO FEED', 'FLOW', false),
  AlarmDef('msiv', 'MSIV', 'CLOSED', false),
  AlarmDef('turbtrip', 'TURBINE', 'TRIP', false),
  AlarmDef('breaker', 'GEN BREAKER', 'OPEN', false),
  AlarmDef('porv', 'PORV', 'OPEN', false),
  AlarmDef('si', 'SAFETY', 'INJECTION', true),
  AlarmDef('contiso', 'CONTAINMENT', 'ISOLATED', true),
  AlarmDef('hirad', 'HI RADIATION', 'CONTAINMENT', true),
  AlarmDef('xenon', 'XENON', 'TRANSIENT', false),
  AlarmDef('damage', 'FUEL CLAD', 'DAMAGE', true),
  AlarmDef('edg', 'DIESEL GEN', 'RUNNING', false),
];

// ===========================================================================
// SECTION 7 — plant physics
// ===========================================================================

enum RodCmd { insert, hold, withdraw }

/// Conditions that simply mean "the plant has not been started yet".
const Set<String> _startupExpected = {
  'scram',
  'msiv',
  'lopress',
  'breaker',
  'turbtrip',
};

class Plant {
  Plant({required this.upgrades});

  Map<String, int> upgrades;

  /// Set by Game so the plant can write its own narrative into the shift log.
  void Function(String who, String text, Color color)? onLog;
  int lvl(String id) => upgrades[id] ?? 0;

  // reactivity
  List<double> rod = [0, 0, 0, 0];
  int bank = 0;
  RodCmd rodCmd = RodCmd.hold;
  bool rodAuto = false;
  double powerSetpoint = 100;
  double boron = 2000;
  int boronCmd = 0;

  double power = 1e-8;
  double decayHeat = 0;
  double xenon = 0;
  double sur = 0;

  bool scrammed = true;
  bool scramLatched = true;
  String scramCause = 'SHUTDOWN';

  // primary
  List<bool> rcp = [false, false, false, false];
  double fuelTemp = 40;
  double tAvg = 40;
  double pressure = 20;
  double pzrLevel = 50;
  int heaters = 0;
  double spray = 0;
  bool porv = false;
  bool pzrAuto = false;

  // secondary
  double feedPump = 0;
  bool frvAuto = true;
  double frvPos = 0;
  bool msiv = false;
  double throttle = 0;
  double sgLevel = 50;
  double steamFlow = 0;
  bool turbineTripped = false;

  // electrical
  bool genBreaker = false;
  double syncAngle = 0;
  bool edg = false;
  bool syncAuto = false;

  // safety
  bool si = false;
  bool contIso = false;
  bool contSpray = false;
  bool afw = false;

  // --- the core's life ------------------------------------------------------
  /// How far through this fuel load you are, 0..100 %. Fission consumes the
  /// fuel and builds poisons, so reactivity falls as it climbs — which is why
  /// a real plant dilutes boron steadily across a fuel cycle. Persists across
  /// shifts: it is the core, not the operator.
  double burnup = 0;

  // --- the grid -------------------------------------------------------------
  /// What the dispatcher is asking you to deliver, in MWe. You are paid for
  /// following it, not just for making power.
  double gridDemand = 0;
  double demandTimer = 0;

  // --- instruments ----------------------------------------------------------
  // Real gauges lag their process and never sit perfectly still. These are the
  // values the meters actually display.
  double iFlux = 0, iFuelT = 40, iTavg = 40, iPress = 20, iSg = 50, iMwe = 0;

  // operator
  /// 0..100. The building is loud, the shift is long, and something in the
  /// turbine hall screams. Hit zero and the operator walks out.
  double sanity = 100;
  double stress = 0; // 0..1, how hard the plant is pushing on you right now
  bool brokeDown = false;

  // outcome
  double damage = 0;
  double radiation = 0;
  double mwe = 0;
  double mwhThisShift = 0;
  double shiftTime = 0;
  double uraniumThisShift = 0;

  final Map<String, AlarmState> alarms = {
    for (final a in kAlarms) a.id: AlarmState.clear
  };
  bool hornSilenced = false;
  bool lampTest = false;

  // --- derived --------------------------------------------------------------
  int get pumpCount => rcp.where((e) => e).length;
  int get pumpsAvailable => 2 + lvl('rcpLoop');
  double get flow => 0.08 + 0.92 * (pumpCount / 4.0);
  double get ratedMWe => 1000 * math.pow(1.12, lvl('uprate')).toDouble();
  double get uraniumPrice =>
      0.06 *
      math.pow(1.18, lvl('gridPrice')).toDouble() *
      math.pow(1.6, lvl('payout')).toDouble();
  double get turbineEff => math.pow(1.08, lvl('turbEff')).toDouble();
  double get rodSpeed => 3.0 * math.pow(1.25, lvl('rodSpeed')).toDouble();
  double get boronSpeed => 14.0 * math.pow(1.3, lvl('boronRate')).toDouble();
  double get heaterPower => 18.0 * math.pow(1.15, lvl('heaterCap')).toDouble();
  double get feedCapacity => math.pow(1.2, lvl('feedCap')).toDouble();
  double get sgInertia => 25.0 / math.pow(1.2, lvl('sgCap')).toDouble();
  double get damageResist => math.pow(0.82, lvl('contain')).toDouble();
  double get scramTrim => lvl('scramMargin') * 1.0;

  /// How far off the requested load you are, as a fraction of rated output.
  double get dispatchError =>
      gridDemand <= 0 ? 0 : (mwe - gridDemand).abs() / math.max(1, ratedMWe);

  /// Paid up to 1.45x for sitting on the requested load, down to 0.6x for
  /// ignoring it. Never zero — power is power.
  double get dispatchFactor {
    if (gridDemand <= 0 || mwe <= 0) return 1;
    return clampD(1.45 - dispatchError * 3.4, 0.6, 1.45);
  }

  /// Remaining reactivity margin before the core simply cannot hold power,
  /// 1 at a fresh load and 0 when it is spent.
  double get fuelMargin => clamp01(1 - burnup / 100);

  double get thermal => power + decayHeat;
  double get thermalMW => thermal * 3000;
  double get rodAvg => (rod[0] + rod[1] + rod[2] + rod[3]) / 4;

  /// Total reactivity, pcm. The temperature term is the stabilizer.
  double get reactivity {
    var rho = 0.0;
    for (final r in rod) {
      rho += r / 100 * 900;
    }
    rho -= boron * 3.5;
    // Moderator temperature coefficient — the slow stabilizer.
    rho -= (tAvg - 300) * 12;
    // Doppler power defect — the prompt one. Fuel broadens its own absorption
    // resonances the instant power rises, which is the single reason a real
    // reactor damps its own transients instead of oscillating.
    rho -= power * 900;
    rho -= xenon * 2500;
    // Fuel depletion and fission-product poisons over the cycle.
    rho -= burnup * 25;
    if (scrammed) rho -= 9000;
    return rho;
  }

  double get fluxDecades =>
      clampD((math.log(math.max(power, 1e-9)) / math.ln10) + 9, 0, 9.5);

  String get rangeName {
    final d = fluxDecades;
    if (d < 3.5) return 'SOURCE RANGE';
    if (d < 6.5) return 'INTERMEDIATE RANGE';
    return 'POWER RANGE';
  }

  double get spdsReactivity =>
      scrammed ? 1.0 : clamp01(1 - (power - 1.0).abs() / 0.3);
  double get spdsCooling =>
      clamp01(pumpCount / 2.0) * clamp01(1 - (fuelTemp - 400) / 800);
  double get spdsIntegrity => clamp01(1 - (pressure - 155).abs() / 45);
  double get spdsContainment => clamp01(1 - radiation / 100);

  bool get anyFlashing => alarms.values.any((s) => s == AlarmState.flashing);
  bool get anyCriticalFlashing => kAlarms
      .any((a) => a.critical && alarms[a.id] == AlarmState.flashing);
  bool get hornActive => anyFlashing && !hornSilenced;

  // --- actions --------------------------------------------------------------
  void scram(String cause) {
    if (scrammed) return;
    scrammed = true;
    scramLatched = true;
    scramCause = cause;
    onLog?.call('REACTOR', 'TRIP — $cause. RODS ON THE BOTTOM.', cRed);
    rodCmd = RodCmd.hold;
    rodAuto = false;
    turbineTripped = true;
    throttle = 0;
    genBreaker = false;
    _raise('scram');
  }

  /// Rods must be fully in and power low before the trip can be reset.
  bool resetScram() {
    if (rodAvg > 1 || power > 0.05) return false;
    scrammed = false;
    scramLatched = false;
    scramCause = '';
    turbineTripped = false;
    onLog?.call('REACTOR', 'TRIP RESET. RODS AVAILABLE.', cGreen);
    return true;
  }

  void ackAlarms() {
    for (final k in alarms.keys) {
      if (alarms[k] == AlarmState.flashing) alarms[k] = AlarmState.acked;
    }
    hornSilenced = true;
  }

  void resetAlarms() {
    for (final a in kAlarms) {
      if (alarms[a.id] == AlarmState.acked && !condition(a.id)) {
        alarms[a.id] = AlarmState.clear;
      }
    }
    hornSilenced = false;
  }

  void _raise(String id) {
    if (alarms[id] == AlarmState.clear) {
      alarms[id] = AlarmState.flashing;
      hornSilenced = false;
    }
  }

  bool condition(String id) {
    switch (id) {
      case 'scram':
        return scrammed;
      case 'hiflux':
        return power > 1.08;
      case 'hifuel':
        return fuelTemp > 900;
      case 'hipress':
        return pressure > 165;
      case 'lopress':
        return pressure < 120 && tAvg > 200;
      case 'hitavg':
        return tAvg > 330;
      case 'loflow':
        return pumpCount < 2 && power > 0.05;
      case 'losg':
        return sgLevel < 25 && tAvg > 150;
      case 'hisg':
        return sgLevel > 85;
      case 'lofeed':
        return feedPump < 5 && steamFlow > 0.05;
      case 'msiv':
        return !msiv && tAvg > 200;
      case 'turbtrip':
        return turbineTripped;
      case 'breaker':
        return !genBreaker && steamFlow > 0.1;
      case 'porv':
        return porv;
      case 'si':
        return si;
      case 'contiso':
        return contIso;
      case 'hirad':
        return radiation > 15;
      case 'xenon':
        return xenon > 0.55;
      case 'damage':
        return damage > 1;
      case 'edg':
        return edg;
    }
    return false;
  }

  // --- the step -------------------------------------------------------------
  void step(double dt) {
    shiftTime += dt;

    // rod motion
    if (scrammed) {
      for (var i = 0; i < 4; i++) {
        rod[i] = math.max(0, rod[i] - 160 * dt);
      }
    } else if (rodAuto && lvl('autoRod') > 0) {
      final err = powerSetpoint / 100 - power;
      final dir = err > 0.01 ? 1.0 : (err < -0.01 ? -1.0 : 0.0);
      rod[bank] = clampD(rod[bank] + dir * rodSpeed * 0.6 * dt, 0, 100);
    } else if (rodCmd != RodCmd.hold) {
      final dir = rodCmd == RodCmd.withdraw ? 1.0 : -1.0;
      rod[bank] = clampD(rod[bank] + dir * rodSpeed * dt, 0, 100);
    }

    if (boronCmd != 0) {
      boron = clampD(boron + boronCmd * boronSpeed * dt, 0, 2500);
    }

    // neutron kinetics
    final rho = clampD(reactivity, -9000, 3000);
    final prev = power;
    // Point kinetics, tuned so ~115 pcm gives a 1 decade/minute startup rate —
    // the same feel as the real procedure the manual describes.
    power *= math.exp(rho / 3000 * dt);
    power += 4e-9 * dt; // source range never truly reaches zero
    power = clampD(power, 1e-9, 2.5);
    if (dt > 0 && prev > 0) {
      final decades = math.log(power / prev) / math.ln10;
      sur += ((decades / dt * 60) - sur) * clamp01(dt * 3);
    }

    decayHeat += (power * 0.07 - decayHeat) * clamp01(dt / 25);

    final xTarget = power / (power + 0.35);
    xenon += (xTarget - xenon) * clamp01(dt / 150);

    // fuel and coolant
    // More coolant loops pull heat out of the fuel harder, so extra pumps are
    // what let you run high power without approaching the fuel temperature trip.
    final fuelTarget = tAvg + thermal * 320 / flow;
    fuelTemp += (fuelTarget - fuelTemp) * clamp01(dt / 3.0);
    fuelTemp = clampD(fuelTemp, 20, 3000);

    // Steam valves stroke over a couple of seconds rather than snapping.
    // Cold water does not boil: steam production collapses below ~280 °C, which
    // is what obliges you to hold the plant at proper operating temperature
    // rather than parking it cold and safe.
    final steamTarget = msiv && !turbineTripped
        ? (throttle / 100) *
            clamp01(pressure / 155) *
            clamp01(sgLevel / 35) *
            clamp01((tAvg - 180) / 100) *
            turbineEff
        : 0.0;
    steamFlow += (steamTarget - steamFlow) * clamp01(dt * 0.6);

    // Thermal inertia: the coolant mass is enormous, so temperature moves over
    // minutes. This is what gives the operator time to react to a mismatch.
    tAvg += ((thermal - steamFlow) * 2.5 - (tAvg - 25) * 0.005) * dt;
    // Reactor coolant pumps dump real mechanical heat into the loop. This is
    // how an actual plant reaches operating temperature before it goes
    // critical, and it keeps the cold startup out of a reactivity trap.
    // The effect fades away as nuclear heat takes over.
    if (pumpCount > 0) {
      tAvg += (320 - tAvg) *
          0.02 *
          pumpCount *
          (1 - clamp01(power * 5)) *
          dt;
    }
    tAvg = clampD(tAvg, 20, 900);

    // pressure
    if (pzrAuto && lvl('autoPzr') > 0) {
      final err = 155 - pressure;
      heaters = err > 3 ? 2 : (err > 0.5 ? 1 : 0);
      spray = err < -3 ? 60 : (err < -0.5 ? 20 : 0);
    }
    final pTarget = 20 +
        math.max(0, tAvg - 100) * 0.55 +
        heaters * heaterPower -
        spray * 0.35;
    pressure += (pTarget - pressure) * clamp01(dt * 0.35);
    if (porv) pressure -= 22 * dt;
    if (pressure > 172 && !porv) pressure -= (pressure - 172) * dt;
    pressure = clampD(pressure, 1, 260);
    pzrLevel = clampD(50 + (pressure - 155) * 0.6 + (tAvg - 300) * 0.2, 0, 100);

    // steam generator
    if (frvAuto) {
      // Position the valve so delivered flow matches steam demand at the
      // current pump setting. If the pump is too small the valve saturates and
      // level falls — which is the plant telling you to raise the feed pump.
      final head = math.max(0.05, (feedPump / 100) * feedCapacity);
      final demand = steamFlow + (50 - sgLevel) * 0.03;
      final target = clampD(demand / head * 100, 0, 100);
      frvPos += (target - frvPos) * clamp01(dt * 1.5);
    }
    var feedFlow = (feedPump / 100) * (frvPos / 100) * feedCapacity;
    if (afw) feedFlow += 0.25;
    sgLevel = clampD(sgLevel + (feedFlow - steamFlow) * sgInertia * dt, 0, 100);

    // grid sync
    if (!genBreaker) {
      syncAngle += (steamFlow - 0.30) * 7.0 * dt;
      if (syncAuto && lvl('autoTurb') > 0 && steamFlow > 0.2) {
        if (math.sin(syncAngle).abs() < 0.1) genBreaker = true;
      }
    }
    while (syncAngle > math.pi) {
      syncAngle -= math.pi * 2;
    }
    while (syncAngle < -math.pi) {
      syncAngle += math.pi * 2;
    }

    mwe = genBreaker && steamFlow > 0.02 ? steamFlow * ratedMWe : 0;
    uraniumThisShift += mwe * uraniumPrice * dispatchFactor * dt;
    mwhThisShift += mwe * dt / 3600;

    if (si) {
      pressure += 6 * dt;
      tAvg -= 3 * dt;
      sgLevel = clampD(sgLevel + 2 * dt, 0, 100);
    }
    if (contSpray) radiation = math.max(0, radiation - 4 * dt);

    autoProtect();

    // damage — only under genuinely abusive conditions
    var dmg = 0.0;
    if (fuelTemp > 1200) dmg += (fuelTemp - 1200) * 0.0016;
    if (pressure > 185) dmg += (pressure - 185) * 0.05;
    if (sgLevel < 4 && thermal > 0.02) dmg += 0.5;
    if (dmg > 0) {
      damage = clampD(damage + dmg * damageResist * dt, 0, 100);
      radiation = clampD(radiation + dmg * 0.6 * dt, 0, 100);
    } else if (lvl('repair') > 0 && damage > 0) {
      damage = math.max(0, damage - lvl('repair') * 0.15 * dt);
    }
    if (radiation > 0 && !contSpray) {
      radiation = math.max(0, radiation - 0.05 * dt);
    }

    // --- fuel burnup ---------------------------------------------------------
    // A full core is roughly three good shifts at high power.
    burnup = clampD(burnup + thermal * 0.035 * dt, 0, 100);

    // --- grid dispatch -------------------------------------------------------
    demandTimer -= dt;
    if (gridDemand <= 0) gridDemand = ratedMWe * 0.6;

    // --- instrument damping --------------------------------------------------
    // Needles chase the process; they do not teleport.
    iFlux += (fluxDecades - iFlux) * clamp01(dt / 0.5);
    iFuelT += (fuelTemp - iFuelT) * clamp01(dt / 1.6);
    iTavg += (tAvg - iTavg) * clamp01(dt / 1.4);
    iPress += (pressure - iPress) * clamp01(dt / 0.7);
    iSg += (sgLevel - iSg) * clamp01(dt / 0.9);
    iMwe += (mwe - iMwe) * clamp01(dt / 0.8);

    // --- operator sanity ----------------------------------------------------
    // Baseline fatigue, plus pressure from everything going wrong at once.
    // Stress comes from what is actually wrong right now, not from tiles you
    // have not pressed yet — otherwise a cleared trip would haunt you all shift.
    var load = 0.0;
    for (final a in kAlarms) {
      if (!condition(a.id)) continue;
      // Before you have generated anything, these five just mean "not started
      // up yet" — the reactor is down, the MSIV is shut, there is no pressure
      // and nothing is on the grid. Charging sanity for them would punish a
      // routine cold start before you had done anything wrong.
      if (mwhThisShift <= 0 && _startupExpected.contains(a.id)) continue;
      load += a.critical ? 0.16 : 0.06;
    }
    // The horn only wears on you when it is telling you something real.
    if (hornActive && load > 0) load += 0.10;
    if (damage > 0) load += clamp01(damage / 40) * 0.8;
    if (radiation > 10) load += clamp01(radiation / 100) * 0.6;
    stress = clamp01(load);
    // Calm plant: about fourteen minutes of composure. Everything going wrong
    // at once: a little over a minute. The canteen is the difference.
    // A calm, well-run plant is nearly restful — about half an hour of
    // composure. It is the trouble that wears you down, not the clock.
    sanity = clampD(sanity - (0.055 + stress * 1.35) * dt, 0, 100);
    if (sanity <= 0) brokeDown = true;

    // alarm scan
    for (final a in kAlarms) {
      if (condition(a.id)) {
        _raise(a.id);
      } else if (alarms[a.id] == AlarmState.acked ||
          (lvl('smartAnn') > 0 && alarms[a.id] == AlarmState.flashing)) {
        alarms[a.id] = AlarmState.clear;
      }
    }
    if (lvl('smartAnn') > 0) hornSilenced = true;
  }

  /// Reactor protection system. This is why death is never inevitable.
  void autoProtect() {
    if (scrammed) return;
    final trim = scramTrim;
    if (power > 1.18 - trim * 0.02) return scram('OVERPOWER');
    if (pressure > 172 - trim) return scram('HI PRESSURE');
    if (fuelTemp > 1050 - trim * 20) return scram('HI FUEL TEMP');
    if (tAvg > 345 - trim * 2) return scram('HI COOLANT TEMP');
    if (sgLevel < 12 + trim && tAvg > 150) return scram('LO SG LEVEL');
    if (pumpCount < 1 && power > 0.05) return scram('LOSS OF FLOW');
  }

  /// Everything a watch consists of. Written whenever the app might be about
  /// to die, so a shift can be picked up exactly where it was left.
  Map<String, dynamic> toJson() => {
        'rod': rod,
        'bank': bank,
        'rodAuto': rodAuto,
        'setp': powerSetpoint,
        'boron': boron,
        'power': power,
        'decay': decayHeat,
        'xenon': xenon,
        'sur': sur,
        'scrammed': scrammed,
        'latched': scramLatched,
        'cause': scramCause,
        'rcp': rcp,
        'fuelT': fuelTemp,
        'tAvg': tAvg,
        'press': pressure,
        'pzr': pzrLevel,
        'heaters': heaters,
        'spray': spray,
        'porv': porv,
        'pzrAuto': pzrAuto,
        'feed': feedPump,
        'frvAuto': frvAuto,
        'frv': frvPos,
        'msiv': msiv,
        'thr': throttle,
        'sg': sgLevel,
        'steam': steamFlow,
        'turbTrip': turbineTripped,
        'brk': genBreaker,
        'sync': syncAngle,
        'edg': edg,
        'syncAuto': syncAuto,
        'si': si,
        'iso': contIso,
        'cspray': contSpray,
        'afw': afw,
        'dmg': damage,
        'rad': radiation,
        'burnup': burnup,
        'demand': gridDemand,
        'demandT': demandTimer,
        'sanity': sanity,
        'stress': stress,
        'mwe': mwe,
        'mwh': mwhThisShift,
        'shiftT': shiftTime,
        'earned': uraniumThisShift,
        'alarms': alarms.map((k, v) => MapEntry(k, v.index)),
        'silenced': hornSilenced,
      };

  /// Restore a watch. Every field is read defensively — a save written by an
  /// older build, or a corrupted one, must not take the game down with it.
  void applyJson(Map<String, dynamic> m) {
    double d(String k, double fallback) {
      final v = m[k];
      return v is num && v.toDouble().isFinite ? v.toDouble() : fallback;
    }

    int i(String k, int fallback) {
      final v = m[k];
      return v is num ? v.toInt() : fallback;
    }

    bool b(String k, bool fallback) {
      final v = m[k];
      return v is bool ? v : fallback;
    }

    List<double> dl(String k, List<double> fallback) {
      final v = m[k];
      if (v is! List || v.length != fallback.length) return fallback;
      return [
        for (final e in v) e is num && e.toDouble().isFinite ? e.toDouble() : 0
      ];
    }

    List<bool> bl(String k, List<bool> fallback) {
      final v = m[k];
      if (v is! List || v.length != fallback.length) return fallback;
      return [for (final e in v) e is bool && e];
    }

    rod = dl('rod', [0, 0, 0, 0]);
    bank = i('bank', 0).clamp(0, 3);
    rodAuto = b('rodAuto', false);
    powerSetpoint = d('setp', 100);
    boron = d('boron', 2000);
    power = d('power', 1e-8);
    decayHeat = d('decay', 0);
    xenon = d('xenon', 0);
    sur = d('sur', 0);
    scrammed = b('scrammed', true);
    scramLatched = b('latched', true);
    scramCause = m['cause'] is String ? m['cause'] as String : '';
    rcp = bl('rcp', [false, false, false, false]);
    fuelTemp = d('fuelT', 40);
    tAvg = d('tAvg', 40);
    pressure = d('press', 20);
    pzrLevel = d('pzr', 50);
    heaters = i('heaters', 0).clamp(0, 2);
    spray = d('spray', 0);
    porv = b('porv', false);
    pzrAuto = b('pzrAuto', false);
    feedPump = d('feed', 0);
    frvAuto = b('frvAuto', true);
    frvPos = d('frv', 0);
    msiv = b('msiv', false);
    throttle = d('thr', 0);
    sgLevel = d('sg', 50);
    steamFlow = d('steam', 0);
    turbineTripped = b('turbTrip', false);
    genBreaker = b('brk', false);
    syncAngle = d('sync', 0);
    edg = b('edg', false);
    syncAuto = b('syncAuto', false);
    si = b('si', false);
    contIso = b('iso', false);
    contSpray = b('cspray', false);
    afw = b('afw', false);
    damage = d('dmg', 0);
    radiation = d('rad', 0);
    burnup = d('burnup', 0);
    gridDemand = d('demand', 0);
    demandTimer = d('demandT', 150);
    sanity = d('sanity', 100);
    stress = d('stress', 0);
    mwe = d('mwe', 0);
    mwhThisShift = d('mwh', 0);
    shiftTime = d('shiftT', 0);
    uraniumThisShift = d('earned', 0);
    hornSilenced = b('silenced', true);
    final a = m['alarms'];
    if (a is Map) {
      for (final def in kAlarms) {
        final v = a[def.id];
        alarms[def.id] = v is num && v.toInt() >= 0 && v.toInt() < AlarmState.values.length
            ? AlarmState.values[v.toInt()]
            : AlarmState.clear;
      }
    }
    // Instruments start wherever the process is, so needles do not sweep up
    // from zero on resume.
    iFlux = fluxDecades;
    iFuelT = fuelTemp;
    iTavg = tAvg;
    iPress = pressure;
    iSg = sgLevel;
    iMwe = mwe;
    brokeDown = false;
  }

  int researchFor() {
    if (mwhThisShift <= 0) return 0;
    final base = math.pow(mwhThisShift / 40, 0.62).toDouble();
    return (base * (1 - clamp01(damage / 100) * 0.75)).floor();
  }

  void startShift({required bool hot}) {
    rod = [0, 0, 0, 0];
    bank = 0;
    rodCmd = RodCmd.hold;
    rodAuto = false;
    boron = 2000;
    boronCmd = 0;
    power = 1e-8;
    decayHeat = 0;
    xenon = 0;
    sur = 0;
    scrammed = true;
    scramLatched = true;
    scramCause = 'SHUTDOWN';
    rcp = [false, false, false, false];
    fuelTemp = 40;
    tAvg = 40;
    pressure = 20;
    heaters = 0;
    spray = 0;
    porv = false;
    pzrAuto = false;
    feedPump = 0;
    frvAuto = true;
    frvPos = 0;
    msiv = false;
    throttle = 0;
    sgLevel = 50;
    steamFlow = 0;
    turbineTripped = false;
    genBreaker = false;
    syncAngle = 0;
    edg = false;
    syncAuto = false;
    si = false;
    contIso = false;
    contSpray = false;
    afw = false;
    damage = 0;
    radiation = 0;
    gridDemand = ratedMWe * (0.55 + 0.2 * (burnup / 100));
    demandTimer = 150;
    iFlux = 0;
    iFuelT = 40;
    iTavg = 40;
    iPress = 20;
    iSg = 50;
    iMwe = 0;
    sanity = 100;
    stress = 0;
    brokeDown = false;
    mwe = 0;
    mwhThisShift = 0;
    uraniumThisShift = 0;
    shiftTime = 0;
    for (final k in alarms.keys) {
      alarms[k] = AlarmState.clear;
    }
    // You take the panel from the off-going crew with the standing alarms
    // already acknowledged; the horn should not be blaring at handover.
    hornSilenced = true;

    if (hot) {
      rcp = [true, true, lvl('rcpLoop') > 0, lvl('rcpLoop') > 1];
      // The off-going crew has already diluted to match the core's age, so the
      // handover is critical whether the fuel is fresh or nearly spent.
      boron = clampD(900 - burnup * 25 / 3.5, 0, 2500);
      rod = [70, 70, 70, 70];
      tAvg = 295;
      fuelTemp = 320;
      pressure = 152;
      power = 0.02;
      scrammed = false;
      scramLatched = false;
      scramCause = '';
      heaters = 1;
      feedPump = 60;
      msiv = true;
    }
  }
}

// ===========================================================================
// SECTION 8 — startup checklist
// ===========================================================================

class Objective {
  const Objective(this.tab, this.text, this.done, this.how);
  final int tab;
  final String text;
  final bool Function(Plant) done;

  /// The extra sentence the tutorial shows. The checklist alone stays terse.
  final String how;
}

final List<Objective> kObjectives = [
  Objective(1, 'Start 2 coolant pumps — flow before anything else',
      (p) => p.pumpCount >= 2, 'COOLANT panel. Turn two RCP grips to RUN. '
          'Their heat also warms the plant, which is how a real startup begins.'),
  Objective(1, 'Wait for T-AVG to pass 280 °C',
      (p) => p.tAvg > 280, 'Pump heat does this on its own. Watch the T-AVG '
          'meter on the left climb.'),
  Objective(1, 'Heaters to HIGH until pressure passes 150 bar',
      (p) => p.pressure > 150, 'Turn the pressurizer knob to HIGH. Back it to '
          'LOW once you are there.'),
  Objective(0, 'Press RESET TRIP to release the rods',
      (p) => !p.scramLatched, 'Bottom bar. The rods are locked down until you '
          'clear the trip.'),
  Objective(0, 'Withdraw all four rod banks',
      (p) => p.rodAvg > 90, 'REACTIVITY panel. Pick a bank A–D, hold OUT until '
          'it reads 100%, then do the next one.'),
  Objective(0, 'Hold DILUTE until the reactor comes alive',
      (p) => p.power > 1e-5, 'Removing boron adds reactivity. Watch SUR — about '
          '1 decade per minute is a controlled startup.'),
  Objective(2, 'Open the MSIV and run feedwater above 60%',
      (p) => p.msiv && p.feedPump > 60, 'STEAM panel. Steam cannot leave '
          'containment until the MSIV is open.'),
  Objective(2, 'Crack the turbine throttle to 15%',
      (p) => p.throttle > 12, 'Drag the THROTTLE bar. This rolls the turbine.'),
  Objective(4, 'Close the generator breaker in phase',
      (p) => p.genBreaker, 'ELECTRICAL panel. Wait for the synchroscope to say '
          'IN PHASE, then throw the breaker. Now you are being paid.'),
  Objective(2, 'Raise throttle and dilute together toward the target',
      (p) => p.power > 0.5, 'More steam pulls more heat out, which raises '
          'reactivity. They move as a pair.'),
];

Objective? nextObjective(Plant p) {
  for (final o in kObjectives) {
    if (!o.done(p)) return o;
  }
  return null;
}

// ===========================================================================
// SECTION 9 — operator's manual
// ===========================================================================

class ManualEntry {
  const ManualEntry(this.control, this.text);
  final String control;
  final String text;
}

class ManualSection {
  const ManualSection(this.title, this.blurb, this.entries);
  final String title;
  final String blurb;
  final List<ManualEntry> entries;
}

const List<ManualSection> kManual = [
  ManualSection(
    'THE JOB',
    'Start the reactor, put megawatts on the grid, get paid in uranium, and '
        'still be standing at the end of the watch.',
    [
      ManualEntry('URANIUM ⬢', 'Fuel and money both. You burn it, they pay you in it.'),
      ManualEntry('RESEARCH ◆', 'Earned per megawatt-hour. Buys permanent upgrades.'),
      ManualEntry('END SHIFT', 'Banks everything, any time. You never have to melt down.'),
    ],
  ),
  ManualSection(
    'STARTUP — the order that works',
    'Heat first, pressure second, fission third, steam last.',
    [
      ManualEntry('1 PUMPS', 'Two coolant pumps. Their heat warms the plant to ~290 °C.'),
      ManualEntry('2 PRESSURE', 'Heaters HIGH until 150 bar, then LOW to hold.'),
      ManualEntry('3 RODS', 'RESET TRIP, then hold OUT on each bank to 100%.'),
      ManualEntry('4 CRITICAL', 'Hold DILUTE. Keep SUR near 1 decade/min.'),
      ManualEntry('5 STEAM', 'MSIV open, feed pump 70%, throttle to 15%.'),
      ManualEntry('6 GRID', 'Close the breaker when the synchroscope says IN PHASE.'),
      ManualEntry('7 LOAD', 'Raise throttle and dilute together.'),
    ],
  ),
  ManualSection(
    'REACTIVITY',
    'Positive means power is rising, zero is steady, negative is falling. Rods '
        'and boron are your controls; temperature is your safety net, because '
        'hotter coolant automatically kills reactivity.',
    [
      ManualEntry('RODS', 'Fast and fine. Hold OUT to raise, IN to lower.'),
      ManualEntry('BORON', 'Slow and broad. DILUTE raises power, BORATE lowers it.'),
      ManualEntry('SUR', 'Decades per minute. Over 3 and you will overshoot into a trip.'),
      ManualEntry('BURNUP', 'Fuel ages and eats reactivity. Dilute a little more each shift.'),
    ],
  ),
  ManualSection(
    'COOLANT AND PRESSURE',
    'Flow first, always. Without it the fuel overheats in seconds.',
    [
      ManualEntry('RCP 1–4', 'Two minimum at power. Losing the last one trips you.'),
      ManualEntry('HEATERS', 'Raise pressure. Target 155 bar.'),
      ManualEntry('SPRAY', 'Drops pressure fast.'),
      ManualEntry('PORV', 'Guarded. Emergency dump. Leaving it open bleeds you dry.'),
    ],
  ),
  ManualSection(
    'STEAM AND GRID',
    'Feed in as much water as you boil off, and match what the dispatcher asks for.',
    [
      ManualEntry('MSIV', 'Open it or no steam leaves containment.'),
      ManualEntry('THROTTLE', 'Your real output control. More steam, more megawatts.'),
      ManualEntry('SG LEVEL', 'Hold near 50%. Below 12% trips the reactor.'),
      ManualEntry('DISPATCH', 'Sit on the requested load: pays 1.45x. Ignore it: 0.6x.'),
    ],
  ),
  ManualSection(
    'WHEN IT GOES WRONG',
    'SCRAM. A trip costs minutes; a meltdown costs everything. Damage only '
        'accumulates above 1200 °C fuel, 185 bar, or a dry steam generator — '
        'and the protection system trips you long before any of that.',
    [
      ManualEntry('SCRAM', 'Guarded. Drops every rod. Always the right answer.'),
      ManualEntry('RESET TRIP', 'Needs rods fully in and power low.'),
      ManualEntry('ACK / SIL / RST', 'Acknowledge alarms, silence the horn, clear cleared tiles.'),
      ManualEntry('SAFETY INJECTION', 'Floods the core. Raises pressure and level fast.'),
    ],
  ),
  ManualSection(
    'STAYING SANE',
    'A calm plant is nearly restful. Trouble is what wears you down — and when '
        'you are already failing, the building starts screaming. Every scream '
        'costs 5 sanity. At zero you walk out.',
    [
      ManualEntry('SIP', 'Button by the sanity bar. One tap, best item for the gap.'),
      ManualEntry('CANTEEN', 'Buy at the desk on the CREW panel, mid-shift, with tonight\'s pay.'),
      ManualEntry('COFFEE', 'BLACK START: three sips, fifteen each.'),
      ManualEntry('AI CREW', 'Bots run one console each. BARISTA-B feeds you below 35.'),
    ],
  ),
];

// ===========================================================================
// SECTION 9b — the shift log
// ===========================================================================
// Everything that happens gets written down in plant language, the way a real
// control room keeps a narrative log. It is also how the room stops feeling
// empty: the dispatcher and the other unit talk to you through it.

class LogEntry {
  LogEntry(this.clock, this.who, this.text, this.color);
  final String clock;
  final String who;
  final String text;
  final Color color;
}

// ===========================================================================
// SECTION 10 — particles (meltdown spectacle)
// ===========================================================================

class Particle {
  Particle({
    required this.pos,
    required this.vel,
    required this.life,
    required this.size,
    required this.color,
    required this.kind,
    this.grav = 0,
    this.rot = 0,
    this.rotV = 0,
  }) : maxLife = life;

  Offset pos;
  Offset vel;
  double life;
  final double maxLife;
  final double size;
  final Color color;
  final int kind; // 0 spark, 1 steam, 2 chunk, 3 ring
  final double grav;
  double rot;
  final double rotV;
}

// ===========================================================================
// SECTION 11 — game controller
// ===========================================================================

enum Screen { home, control, shop, manual, report }

class Game {
  Game() {
    plant = Plant(upgrades: upgrades);
    load();
  }

  late Plant plant;
  final Sfx sfx = Sfx();
  final Map<String, int> upgrades = {};

  double uranium = 0;
  int research = 0;

  /// Sips remaining per canteen item. Buying a unit adds that item's sips.
  final Map<String, int> pantry = {};
  double lifetimeMwh = 0;
  double bestShiftMwh = 0;
  int shifts = 0;
  int meltdowns = 0;
  int trips = 0;

  Screen screen = Screen.home;
  int consoleTab = 0;
  int shopTab = 0;
  bool shiftActive = false;

  // report card
  double reportUranium = 0;
  double reportMwh = 0;
  int reportResearch = 0;
  bool reportMelted = false;
  bool reportBrokeDown = false;
  double reportTime = 0;

  // offline
  double offlineGain = 0;
  double offlineAway = 0;
  double lastMwe = 0;

  // --- the shift ------------------------------------------------------------
  /// Night shift. Wall-clock minutes run 30x real time, so a quarter of an
  /// hour at the desk covers most of a watch.
  static const double shiftStartMinutes = 22 * 60;
  double get clockMinutes => shiftStartMinutes + plant.shiftTime * 0.5;
  String get clockText {
    final m = clockMinutes.floor() % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  final List<LogEntry> log = [];
  double logFlash = 0; // seconds the newest entry stays on the status strip

  void logEvent(String who, String text, [Color color = cInkDim]) {
    log.add(LogEntry(clockText, who, text, color));
    if (log.length > 60) log.removeAt(0);
    logFlash = 5;
    bump();
  }

  // the noise
  double screamIn = 30;
  double screamFlash = 0; // 0..1, the visual jolt right after one
  int screamsHeard = 0;

  // visuals
  double t = 0;
  double shake = 0;
  double flash = 0;
  double meltT = -1; // >=0 while the meltdown cinematic plays
  final List<Particle> particles = [];
  final math.Random rng = math.Random();

  /// Painters listen to this. Bumped once per frame — nothing rebuilds.
  final ValueNotifier<int> frame = ValueNotifier<int>(0);

  /// Widgets listen to this. Bumped only on discrete state changes.
  final ValueNotifier<int> ui = ValueNotifier<int>(0);

  int lvl(String id) => upgrades[id] ?? 0;

  void bump() => ui.value++;

  // --- canteen --------------------------------------------------------------
  int sipsOf(String id) => pantry[id] ?? 0;
  int get totalSips => pantry.values.fold(0, (a, b) => a + b);

  /// Everything you have earned, including this shift — so you can restock at
  /// the desk instead of waiting for the watch to end.
  double get spendable => uranium + plant.uraniumThisShift;

  /// Take from what you have banked first, then from tonight's earnings.
  void _spend(double amount) {
    final fromBank = math.min(uranium, amount);
    uranium -= fromBank;
    plant.uraniumThisShift =
        math.max(0, plant.uraniumThisShift - (amount - fromBank));
  }

  bool buyConsumable(Consumable c) {
    if (spendable < c.cost) {
      sfx.deny();
      return false;
    }
    _spend(c.cost);
    pantry[c.id] = sipsOf(c.id) + c.sips;
    sfx.buy();
    save();
    bump();
    return true;
  }

  /// Take one sip of an item. Returns false when there is none left or the
  /// operator is already fully composed.
  bool sip(String id) {
    if (sipsOf(id) <= 0) {
      sfx.deny();
      return false;
    }
    final c = canteenItem(id);
    pantry[id] = sipsOf(id) - 1;
    plant.sanity = clampD(plant.sanity + c.perSip, 0, 100);
    sfx.sip();
    save();
    bump();
    return true;
  }

  /// The item the quick-sip button and BARISTA-B reach for: smallest useful
  /// portion first, so a big meal is not wasted topping up two points.
  String? bestSip() {
    final have = kCanteen.where((c) => sipsOf(c.id) > 0).toList();
    if (have.isEmpty) return null;
    final missing = 100 - plant.sanity;
    have.sort((a, b) {
      final da = (a.perSip - missing).abs();
      final db = (b.perSip - missing).abs();
      return da.compareTo(db);
    });
    return have.first.id;
  }

  // --- economy --------------------------------------------------------------
  double costOf(ShopItem it) => it.costAt(lvl(it.id));

  bool canAfford(ShopItem it) {
    if (lvl(it.id) >= it.maxLevel) return false;
    return it.research ? research >= costOf(it) : spendable >= costOf(it);
  }

  int get affordableCount => kShop.where(canAfford).length;

  bool buy(ShopItem it) {
    if (!canAfford(it)) {
      sfx.deny();
      return false;
    }
    final c = costOf(it);
    if (it.research) {
      research -= c.round();
    } else {
      _spend(c);
    }
    upgrades[it.id] = lvl(it.id) + 1;
    sfx.buy();
    save();
    bump();
    return true;
  }

  // --- shift flow -----------------------------------------------------------
  void startShift() {
    plant.onLog = logEvent;
    log.clear();
    plant.startShift(hot: lvl('hotStart') > 0);
    scheduleScream();
    screamFlash = 0;
    screamsHeard = 0;
    logEvent('SHIFT', 'WATCH ASSUMED. UNIT 1 ${lvl('hotStart') > 0 ? "AT HOT STANDBY" : "COLD SHUTDOWN"}.', cGreen);
    logEvent('FUEL', 'CORE AT ${plant.burnup.round()}% BURNUP.',
        plant.burnup > 80 ? cRed : cInkDim);
    logEvent('GRID DISPATCH',
        'TARGET ${plant.gridDemand.round()} MWe FOR THIS WATCH.', cGold);
    if (shifts == 0 && totalSips > 0) {
      logEvent('CANTEEN',
          'FLASK AND WATER IN YOUR BAG. SIP WHEN SANITY DROPS.', cViolet);
    }
    shiftActive = true;
    screen = Screen.control;
    consoleTab = plant.scramLatched ? 1 : 0;
    meltT = -1;
    particles.clear();
    sfx.powerUp();
    bump();
  }

  void endShift({required bool melted, bool brokeDown = false}) {
    reportUranium = plant.uraniumThisShift;
    reportMwh = plant.mwhThisShift;
    reportResearch = plant.researchFor();
    reportMelted = melted;
    reportBrokeDown = brokeDown;
    if (melted) plant.burnup = 0; // there is nothing left of that core
    if (brokeDown) {
      logEvent('SHIFT', 'OPERATOR LEFT THE DESK. WATCH ABANDONED.', cViolet);
    }
    reportTime = plant.shiftTime;
    // Walking out mid-shift means the paperwork never gets filed.
    if (brokeDown) reportResearch = (reportResearch * 0.4).floor();
    uranium += reportUranium;
    research += reportResearch;
    lifetimeMwh += reportMwh;
    if (reportMwh > bestShiftMwh) bestShiftMwh = reportMwh;
    shifts++;
    if (melted) meltdowns++;
    lastMwe = melted ? 0 : plant.mwe;
    shiftActive = false;
    screamIn = 30;
    screamFlash = 0;
    screen = Screen.report;
    save();
    bump();
  }

  /// When the next scream is due. A calm, well-run plant is left alone; the
  /// building only starts on you once you are already in trouble. Chaos is
  /// something you earn, not weather.
  void scheduleScream() {
    final p = plant;
    var trouble = p.stress;
    if (p.damage > 0) trouble += clamp01(p.damage / 30) * 0.7;
    if (p.scrammed && p.shiftTime > 30) trouble += 0.25;
    trouble = clamp01(trouble);
    // Quiet watch: five to nine minutes between anything. Falling apart: under
    // half a minute.
    final base = lerpD(300, 25, trouble);
    screamIn = base + rng.nextDouble() * base * 0.8;
  }

  /// The dispatcher's next request. Real load-following: they tell you what
  /// the grid needs and you go and get it.
  void requestLoad() {
    final p = plant;
    final frac = 0.35 + rng.nextDouble() * 0.6;
    final want = (p.ratedMWe * frac / 10).round() * 10.0;
    p.gridDemand = want;
    p.demandTimer = 150 + rng.nextDouble() * 150;
    final up = want > p.mwe;
    logEvent(
      'GRID DISPATCH',
      '${up ? "RAISE" : "REDUCE"} TO ${want.round()} MWe',
      cGold,
    );
  }

  void hearScream() {
    // Ear defenders do not stop it. They just take the edge off.
    final damp = math.pow(0.6, lvl('earDefenders')).toDouble();
    plant.sanity = clampD(plant.sanity - 5 * damp, 0, 100);
    if (plant.sanity <= 0) plant.brokeDown = true;
    screamsHeard++;
    screamFlash = 1;
    shake = math.min(1.0, shake + 0.22);
    sfx.scream();
    logEvent('TURBINE HALL',
        const [
          'SOUND AGAIN. NO CAUSE FOUND.',
          'SCREAMING FROM THE 12M LEVEL. HALL IS EMPTY.',
          'UNIT 2 REPORTS NOTHING. UNIT 2 IS DECOMMISSIONED.',
          'SAME SOUND. SAME PLACE. LOGGED.',
          'MAINTENANCE WILL NOT GO DOWN THERE AT NIGHT.',
        ][screamsHeard % 5],
        cRed);
  }

  /// The hired help. Each bot works one console the way a competent operator
  /// would, and only if you actually bought it.
  void runBots(double dt) {
    final p = plant;
    if (lvl('watchBot') > 0 && p.anyFlashing) {
      p.ackAlarms();
    }
    if (lvl('feedBot') > 0 && p.msiv) {
      // Chase steam demand plus a nudge back toward 50% level.
      final want = clampD((p.steamFlow * 100 + (50 - p.sgLevel) * 2.2), 0, 100);
      p.feedPump += (want - p.feedPump) * clamp01(dt * 0.8);
    }
    if (lvl('baristaBot') > 0 && p.sanity < 35) {
      _baristaCool -= dt;
      if (_baristaCool <= 0) {
        _baristaCool = 3;
        final pick = bestSip();
        if (pick != null) sip(pick);
      }
    }
  }

  double _baristaCool = 0;

  /// A refuelling outage. Costs uranium in proportion to how much of the core
  /// you are replacing, and hands you a fresh one.
  double get refuelCost => 40 * plant.burnup * math.pow(1.05, lvl('uprate')).toDouble();

  bool refuel() {
    if (plant.burnup < 1) {
      sfx.deny();
      return false;
    }
    final cost = refuelCost;
    if (spendable < cost) {
      sfx.deny();
      return false;
    }
    _spend(cost);
    plant.burnup = 0;
    plant.xenon = 0;
    refuels++;
    sfx.powerUp();
    save();
    bump();
    return true;
  }

  int refuels = 0;

  /// On until you finish a startup or skip it. Adds a coaching card and jumps
  /// the console to whichever panel the current step lives on — it teaches the
  /// room, it does not do the job for you.
  bool tutorial = true;
  int _tutorialTab = -1;

  void skipTutorial() {
    tutorial = false;
    sfx.softClick();
    logEvent('SHIFT', 'TUTORIAL OFF. YOU ARE ON YOUR OWN.', cInkDim);
    save();
    bump();
  }

  /// Follow the checklist to whichever panel the next step needs.
  void followTutorial() {
    if (!tutorial || !shiftActive) return;
    final o = nextObjective(plant);
    if (o == null) {
      tutorial = false;
      logEvent('SHIFT', 'STARTUP COMPLETE. YOU HAVE THE WATCH.', cGreen);
      save();
      bump();
      return;
    }
    if (o.tab != _tutorialTab) {
      _tutorialTab = o.tab;
      consoleTab = o.tab;
      bump();
    }
  }

  void triggerMeltdown() {
    if (meltT >= 0) return;
    meltT = 0;
    shake = 1.0;
    flash = 1.0;
    logEvent('CONTAINMENT', 'FUEL FAILURE. CORE IS LOST.', cRed);
    sfx.meltdown();
    spawnExplosion(const Offset(0, 0));
  }

  void spawnExplosion(Offset c) {
    for (var i = 0; i < 3; i++) {
      particles.add(Particle(
        pos: c,
        vel: Offset.zero,
        life: 0.5 + i * 0.22,
        size: 10.0 + i * 34,
        color: i == 0 ? Colors.white : const Color(0xFFFF8030),
        kind: 3,
      ));
    }
    for (var i = 0; i < 80; i++) {
      final a = rng.nextDouble() * math.pi * 2;
      final sp = 120 + rng.nextDouble() * 520;
      const palette = [
        Colors.white,
        cGold,
        Color(0xFFFF8030),
        Color(0xFFFF4020),
      ];
      particles.add(Particle(
        pos: c,
        vel: Offset(math.cos(a), math.sin(a)) * sp,
        life: 0.7 + rng.nextDouble() * 1.1,
        size: 2 + rng.nextDouble() * 3.5,
        color: palette[rng.nextInt(palette.length)],
        kind: 0,
        grav: 260,
      ));
    }
    for (var i = 0; i < 22; i++) {
      final a = rng.nextDouble() * math.pi * 2;
      final sp = 90 + rng.nextDouble() * 330;
      particles.add(Particle(
        pos: c,
        vel: Offset(math.cos(a) * sp, math.sin(a) * sp - 120),
        life: 1.2 + rng.nextDouble(),
        size: 6 + rng.nextDouble() * 10,
        color: const Color(0xFF3A424D),
        kind: 2,
        grav: 520,
        rotV: rng.nextDouble() * 14 - 7,
      ));
    }
    for (var i = 0; i < 26; i++) {
      particles.add(Particle(
        pos: c + Offset(rng.nextDouble() * 160 - 80, rng.nextDouble() * 80 - 40),
        vel: Offset(rng.nextDouble() * 30 - 15, -40 - rng.nextDouble() * 40),
        life: 1.5 + rng.nextDouble(),
        size: 12 + rng.nextDouble() * 14,
        color: const Color(0xFF808A96),
        kind: 1,
      ));
    }
  }

  // --- audio bookkeeping ----------------------------------------------------
  double _hornAcc = 0;
  double _geigerAcc = 0;
  double _rodAcc = 0;
  bool _wasScrammed = true;

  void audioFrame(double dt) {
    if (!shiftActive) return;
    final p = plant;

    if (p.hornActive) {
      _hornAcc += dt;
      final period = p.anyCriticalFlashing ? 1.1 : 1.8;
      if (_hornAcc >= period) {
        _hornAcc = 0;
        p.anyCriticalFlashing ? sfx.criticalHorn() : sfx.horn();
      }
    } else {
      _hornAcc = 999;
    }

    final rad = math.max(p.radiation, p.damage);
    if (rad > 2) {
      _geigerAcc += dt * (0.5 + clamp01(rad / 100) * 8);
      while (_geigerAcc >= 1) {
        _geigerAcc -= 1;
        sfx.geiger(clamp01(rad / 100));
      }
    }

    if (!p.scrammed && p.rodCmd != RodCmd.hold) {
      _rodAcc += dt;
      if (_rodAcc >= 0.14) {
        _rodAcc = 0;
        sfx.rodStep();
      }
    }

    if (p.scrammed && !_wasScrammed) {
      sfx.scram();
      shake = math.min(1.0, shake + 0.55);
      trips++;
    }
    _wasScrammed = p.scrammed;
  }

  // --- frame ----------------------------------------------------------------
  static const double kStep = 0.05;
  double _acc = 0;
  double _saveAcc = 0;

  void tick(double raw) {
    t += raw;

    if (shiftActive && meltT < 0) {
      _acc += raw;
      var n = 0;
      while (_acc >= kStep && n < 40) {
        plant.step(kStep);
        _acc -= kStep;
        n++;
      }
      if (n == 40) _acc = 0;

      // The dispatcher calls with a new load target now and then.
      plant.demandTimer -= raw;
      if (plant.demandTimer <= 0) requestLoad();
      logFlash = math.max(0, logFlash - raw);
      followTutorial();

      // Something screams somewhere in the building. You never find out what.
      screamIn -= raw;
      if (screamIn <= 0) {
        scheduleScream();
        hearScream();
      }
      screamFlash = math.max(0, screamFlash - raw * 1.6);

      runBots(raw);

      if (plant.damage >= 100) triggerMeltdown();
      if (plant.brokeDown && meltT < 0) {
        endShift(melted: false, brokeDown: true);
        return;
      }
      audioFrame(raw);
    }

    if (meltT >= 0) {
      meltT += raw;
      if (meltT > 2.6) {
        meltT = -1;
        endShift(melted: true);
      }
    }

    shake = math.max(0, shake - raw * 0.9);
    flash = math.max(0, flash - raw * 1.4);

    for (final p in particles) {
      p.life -= raw;
      p.vel = Offset(p.vel.dx, p.vel.dy + p.grav * raw);
      p.pos += p.vel * raw;
      p.rot += p.rotV * raw;
    }
    particles.removeWhere((p) => p.life <= 0);

    _saveAcc += raw;
    if (_saveAcc > (shiftActive ? 3 : 10)) {
      _saveAcc = 0;
      save();
    }

    frame.value++;
  }

  // --- persistence ----------------------------------------------------------
  double _fin(double v) => v.isFinite ? v : 1e300;

  void save() {
    rawSave(jsonEncode({
      'v': 3,
      // A watch in progress, so closing the app does not throw it away.
      'active': shiftActive,
      if (shiftActive) 'shift': plant.toJson(),
      if (shiftActive)
        'log': [
          for (final e in log.length > 40 ? log.sublist(log.length - 40) : log)
            {'c': e.clock, 'w': e.who, 't': e.text, 'k': e.color.toARGB32()}
        ],
      'ur': _fin(uranium),
      'rs': research,
      'up': upgrades,
      'pan': pantry,
      'bu': _fin(plant.burnup),
      'rf': refuels,
      'tut': tutorial,
      'mwh': _fin(lifetimeMwh),
      'best': _fin(bestShiftMwh),
      'sh': shifts,
      'md': meltdowns,
      'tr': trips,
      'mu': sfx.muted,
      'lm': _fin(lastMwe),
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  /// What you turn up with on your first night: a flask of coffee and a bottle
  /// of water. Without it a new operator cannot buy anything yet and simply
  /// runs out of sanity before earning their first uranium.
  void _stockStarterKit() {
    pantry['coffee'] = 3;
    pantry['water'] = 5;
  }

  void load() {
    final raw = rawLoad();
    if (raw == null) {
      _stockStarterKit();
      return;
    }
    Map<String, dynamic> m;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      m = decoded;
    } catch (_) {
      // Unreadable save: start clean rather than refuse to launch.
      _stockStarterKit();
      return;
    }

    // Every field is read defensively and independently, so one bad value
    // costs that value and nothing else.
    double d(String k) {
      final v = m[k];
      return v is num && v.toDouble().isFinite ? v.toDouble() : 0;
    }

    int i(String k) {
      final v = m[k];
      return v is num ? v.toInt() : 0;
    }

    uranium = d('ur') != 0 ? d('ur') : d('cr'); // 'cr' was the old key
    research = i('rs');
    final up = m['up'];
    if (up is Map) {
      up.forEach((k, v) {
        if (v is num) upgrades['$k'] = v.toInt();
      });
    }
    final pan = m['pan'];
    if (pan is Map) {
      pan.forEach((k, v) {
        if (v is num && v.toInt() > 0) pantry['$k'] = v.toInt();
      });
    }
    lifetimeMwh = d('mwh');
    bestShiftMwh = d('best');
    shifts = i('sh');
    meltdowns = i('md');
    trips = i('tr');
    refuels = i('rf');
    lastMwe = d('lm');
    sfx.muted = m['mu'] is bool ? m['mu'] as bool : false;
    tutorial = m['tut'] is bool ? m['tut'] as bool : false;
    plant.burnup = d('bu');

    // A watch that was still running when the app went away.
    final shift = m['shift'];
    if ((m['active'] is bool && m['active'] as bool) &&
        shift is Map<String, dynamic>) {
      plant.onLog = logEvent;
      plant.applyJson(shift);
      shiftActive = true;
      screen = Screen.control;
      _tutorialTab = -1;
      final entries = m['log'];
      if (entries is List) {
        for (final e in entries) {
          if (e is Map) {
            log.add(LogEntry(
              e['c'] is String ? e['c'] as String : '--:--',
              e['w'] is String ? e['w'] as String : 'LOG',
              e['t'] is String ? e['t'] as String : '',
              e['k'] is num ? Color(e['k'] as int) : cInkDim,
            ));
          }
        }
      }
      scheduleScream();
      logEvent('SHIFT', 'WATCH RESUMED. PLANT AS YOU LEFT IT.', cGreen);
    }

    final ts = i('ts');
    if (ts > 0 && !shiftActive) {
      final away = (DateTime.now().millisecondsSinceEpoch - ts) / 1000.0;
      if (away > 30) applyOffline(away);
    }
  }

  /// Remote dispatch: the plant keeps selling power while you are away, at a
  /// reduced rate and only if the licence upgrade is owned.
  void applyOffline(double seconds) {
    final l = lvl('dispatch');
    if (l <= 0 || lastMwe <= 0) return;
    final capSec = (4.0 + 4.0 * l) * 3600.0;
    final rate = 0.3 * l;
    final gain =
        lastMwe * plant.uraniumPrice * math.min(seconds, capSec) * rate;
    if (gain <= 0) return;
    uranium += gain;
    offlineGain = gain;
    offlineAway = seconds;
  }

  void wipe() {
    rawWipe();
    uranium = 0;
    research = 0;
    upgrades.clear();
    pantry.clear();
    _stockStarterKit();
    refuels = 0;
    tutorial = true;
    log.clear();
    lifetimeMwh = 0;
    bestShiftMwh = 0;
    shifts = 0;
    meltdowns = 0;
    trips = 0;
    lastMwe = 0;
    shiftActive = false;
    screen = Screen.home;
    plant = Plant(upgrades: upgrades);
    particles.clear();
    bump();
  }
}

// ===========================================================================
// SECTION 12 — text helpers
// ===========================================================================

TextStyle ts(double size, Color color,
        {FontWeight w = FontWeight.w700, double ls = 0.6}) =>
    TextStyle(
      fontSize: size,
      color: color,
      fontWeight: w,
      letterSpacing: ls,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// Cheap canvas text. Painters draw all live readouts so no widget rebuilds.
void drawText(
  Canvas canvas,
  String text,
  Offset at, {
  double size = 10,
  Color color = cInk,
  FontWeight weight = FontWeight.w700,
  double ls = 0.5,
  TextAlign align = TextAlign.left,
  double maxWidth = 400,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        color: color,
        fontWeight: weight,
        letterSpacing: ls,
        height: 1.15,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(maxWidth: maxWidth);
  var dx = at.dx;
  if (align == TextAlign.center) dx -= tp.width / 2;
  if (align == TextAlign.right) dx -= tp.width;
  tp.paint(canvas, Offset(dx, at.dy));
}

// ===========================================================================
// SECTION 13 — app shell
// ===========================================================================

class ReactorApp extends StatelessWidget {
  const ReactorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MELTDOWN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const GameRoot(),
    );
  }
}

class GameRoot extends StatefulWidget {
  const GameRoot({super.key});

  @override
  GameRootState createState() => GameRootState();
}

class GameRootState extends State<GameRoot>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Game game;
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    game = Game();
    WidgetsBinding.instance.addObserver(this);
    game.ui.addListener(_onUi);
    _ticker = createTicker(_tick)..start();
  }

  void _onUi() => setState(() {});

  @override
  void dispose() {
    game.save();
    game.ui.removeListener(_onUi);
    _ticker.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Anything other than resumed can be the last moment we get.
    if (state != AppLifecycleState.resumed) game.save();
  }

  @override
  void didChangeMetrics() => game.save();

  void _tick(Duration elapsed) {
    final raw = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (raw <= 0) return;
    game.tick(raw > 1 ? 1 / 60 : raw);
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (game.screen) {
      case Screen.home:
        body = HomeScreen(game: game);
      case Screen.control:
        body = ControlRoom(game: game);
      case Screen.shop:
        body = ShopScreen(game: game);
      case Screen.manual:
        body = ManualScreen(game: game);
      case Screen.report:
        body = ReportScreen(game: game);
    }
    return Scaffold(
      backgroundColor: cBg,
      body: ShakeWrap(game: game, child: body),
    );
  }
}

/// Applies screen shake and the white flash without rebuilding the subtree:
/// both are driven by the frame notifier through an AnimatedBuilder that only
/// rewraps an already-built child.
class ShakeWrap extends StatelessWidget {
  const ShakeWrap({super.key, required this.game, required this.child});
  final Game game;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: game.frame,
      child: child,
      builder: (context, ch) {
        final s = clampD(game.shake, 0, 1);
        final amp = 13 * math.pow(s, 1.4).toDouble();
        final t = game.t;
        final m = s > 0.004
            ? (Matrix4.translationValues(
                (math.sin(t * 73.7) + math.sin(t * 47.3)) * 0.5 * amp,
                (math.sin(t * 67.1 + 1.7) + math.sin(t * 53.9 + 0.6)) * 0.5 * amp,
                0,
              )..rotateZ(math.sin(t * 59.3 + 0.9) * 0.012 * s))
            : Matrix4.identity();
        return Stack(
          fit: StackFit.expand,
          children: [
            Transform(transform: m, alignment: Alignment.center, child: ch),
            if (game.particles.isNotEmpty)
              IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: FxPainter(game: game, repaint: game.frame),
                    size: Size.infinite,
                  ),
                ),
              ),
            if (game.flash > 0.001)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.white
                      .withValues(alpha: clampD(game.flash * 0.85, 0, 1)),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ===========================================================================
// SECTION 14 — shared chrome
// ===========================================================================

class PanelBox extends StatelessWidget {
  const PanelBox({
    super.key,
    required this.child,
    this.color = cPanel,
    this.pad = const EdgeInsets.all(10),
    this.border,
  });
  final Widget child;
  final Color color;
  final EdgeInsets pad;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border ?? cEdge),
      ),
      child: child,
    );
  }
}

class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color = cGreen,
    this.sub,
    this.glyph,
    this.badge,
    this.height = 54,
  });
  final String label;
  final String? sub;
  final String? glyph;
  final int? badge;
  final Color color;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.75), width: 1.5),
        ),
        child: Row(
          children: [
            if (glyph != null) ...[
              Text(glyph!, style: TextStyle(fontSize: 20, color: color)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Long legends shrink rather than push the button open.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(label,
                        maxLines: 1,
                        style: ts(14, color, w: FontWeight.w900, ls: 1.4)),
                  ),
                  if (sub != null)
                    Text(sub!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(10, cInkDim, w: FontWeight.w600)),
                ],
              ),
            ),
            if (badge != null && badge! > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: cGold,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('$badge',
                    style: ts(11, Colors.black, w: FontWeight.w900)),
              ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// SECTION 15 — home screen
// ===========================================================================

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final hot = g.lvl('hotStart') > 0;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 26),
            children: [
              // ---- hero: the containment hexagon, breathing --------------
              SizedBox(
                height: 168,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: HomeHeroPainter(game: g, repaint: g.frame),
                    size: Size.infinite,
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ---- what you own ------------------------------------------
              Row(
                children: [
                  Expanded(
                    child: _card('⬢', 'URANIUM', fmt(g.uranium), cGold),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _card('◆', 'RESEARCH', '${g.research}', cViolet),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PanelBox(
                pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    _mini('SHIFTS', '${g.shifts}', cInk),
                    _mini('BEST MWh', fmt(g.bestShiftMwh), cCyan),
                    _mini('TRIPS', '${g.trips}', cAmber),
                    _mini('MELTDOWNS', '${g.meltdowns}', cRed),
                  ],
                ),
              ),

              if (g.offlineGain > 0) ...[
                const SizedBox(height: 8),
                PanelBox(
                  border: cViolet.withValues(alpha: 0.5),
                  pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: Row(
                    children: [
                      Text('⧗', style: ts(16, cViolet)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Remote dispatch earned ⬢${fmt(g.offlineGain)} while '
                          'you were away ${formatDur(g.offlineAway)}.',
                          style: ts(10.5, cInk, w: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 14),
              BigButton(
                label: g.shiftActive ? 'RESUME WATCH' : 'START SHIFT',
                sub: g.shiftActive
                    ? 'Your plant is exactly as you left it'
                    : (hot
                        ? 'Hot standby handover — already critical'
                        : 'Cold start — pumps, rods, heat, steam, sync'),
                glyph: '⏻',
                color: cGreen,
                height: 60,
                onTap: () {
                  if (g.shiftActive) {
                    g.screen = Screen.control;
                    g.bump();
                  } else {
                    g.startShift();
                  }
                },
              ),

              if (g.plant.burnup > 1) ...[
                const SizedBox(height: 8),
                BigButton(
                  label: 'REFUELLING OUTAGE',
                  sub: 'Core at ${g.plant.burnup.round()}% burnup · '
                      '⬢${fmt(g.refuelCost)}',
                  glyph: '⬢',
                  color: g.plant.burnup > 80 ? cRed : cAmber,
                  onTap: () {
                    if (g.refuel()) g.sfx.chime();
                  },
                ),
              ],

              const SizedBox(height: 8),
              BigButton(
                label: 'UPGRADES',
                sub: '${kShop.length} systems · ${g.affordableCount} affordable',
                glyph: '⚙',
                color: cGold,
                badge: g.affordableCount,
                onTap: () {
                  g.sfx.softClick();
                  g.screen = Screen.shop;
                  g.bump();
                },
              ),
              const SizedBox(height: 8),
              BigButton(
                label: 'OPERATOR MANUAL',
                sub: 'Every control explained — tap ♪ to hear it',
                glyph: '▥',
                color: cBlue,
                onTap: () {
                  g.sfx.softClick();
                  g.screen = Screen.manual;
                  g.bump();
                },
              ),

              const SizedBox(height: 16),
              Text(
                'The plant is stable when balanced and trips before it breaks. '
                'Losing the core takes real neglect — losing yourself is easier.',
                textAlign: TextAlign.center,
                style: ts(10, cInkFaint, w: FontWeight.w500, ls: 0.1),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _WipeButton(game: g)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      g.sfx.muted = !g.sfx.muted;
                      if (!g.sfx.muted) g.sfx.chime();
                      g.save();
                      g.bump();
                    },
                    child: Container(
                      width: 44,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: cEdge),
                      ),
                      child: Text(g.sfx.muted ? '∅' : '♪',
                          style: ts(12, g.sfx.muted ? cInkFaint : cInkDim)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(String glyph, String label, String value, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.withValues(alpha: 0.13), cPanel],
          ),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Text(glyph, style: ts(17, c, w: FontWeight.w900)),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: ts(7.5, cInkFaint, ls: 1.3)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(value,
                        maxLines: 1, style: ts(17, c, w: FontWeight.w900)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _mini(String label, String value, Color c) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(7.5, cInkFaint, ls: 1)),
            const SizedBox(height: 1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  maxLines: 1, style: ts(13, c, w: FontWeight.w900)),
            ),
          ],
        ),
      );
}

/// The front door: the same containment hexagon as the app icon, with a core
/// that breathes and a wordmark sitting in it.
class HomeHeroPainter extends GamePainter {
  HomeHeroPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final t = game.t;
    final cx = size.width / 2;
    // Keep the emblem clear of the wordmark beneath it.
    final cy = size.height * 0.34;
    final r = math.min(size.width * 0.30, size.height * 0.32);

    // Faint console grid, so it reads as a panel rather than a poster.
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.028)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 26) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 26) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Core glow, breathing.
    final pulse = 0.5 + 0.5 * math.sin(t * 1.5);
    final glowR = r * (0.95 + 0.10 * pulse);
    canvas.drawCircle(
      Offset(cx, cy),
      glowR,
      Paint()
        ..shader = RadialGradient(colors: [
          cGreen.withValues(alpha: 0.38 + 0.12 * pulse),
          cGreen.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: glowR)),
    );

    // Fuel rods.
    for (var i = 0; i < 4; i++) {
      final x = cx + (i - 1.5) * r * 0.30;
      canvas.drawLine(
        Offset(x, cy - r * 0.62),
        Offset(x, cy + r * 0.02),
        Paint()
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFFC8D4E0).withValues(alpha: 0.85),
      );
    }

    // Containment hexagon.
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final p = Offset(cx + math.cos(a) * r, cy + math.sin(a) * r * 0.92);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round
        ..color = cGold,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..color = cGold.withValues(alpha: 0.12),
    );

    // Wordmark.
    drawText(canvas, 'MELTDOWN', Offset(cx, size.height - 40),
        size: 28,
        color: cGreen,
        align: TextAlign.center,
        weight: FontWeight.w900,
        ls: 7,
        maxWidth: size.width);
    drawText(canvas, 'PRESSURIZED WATER REACTOR · CONTROL ROOM',
        Offset(cx, size.height - 11),
        size: 7.5,
        color: cInkFaint,
        align: TextAlign.center,
        ls: 1.9,
        maxWidth: size.width);
  }
}

class _WipeButton extends StatefulWidget {
  const _WipeButton({required this.game});
  final Game game;
  @override
  State<_WipeButton> createState() => _WipeButtonState();
}

class _WipeButtonState extends State<_WipeButton> {
  bool armed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (armed) {
          widget.game.wipe();
          setState(() => armed = false);
        } else {
          setState(() => armed = true);
        }
      },
      child: Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cRed.withValues(alpha: 0.45)),
        ),
        child: Text(
          armed ? 'TAP AGAIN TO ERASE ALL PROGRESS' : 'DECOMMISSION — erase save',
          style: ts(10, cRed.withValues(alpha: 0.85)),
        ),
      ),
    );
  }
}

// ===========================================================================
// SECTION 16 — report screen
// ===========================================================================

class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key, required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final melted = g.reportMelted;
    final broke = g.reportBrokeDown;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(22),
            children: [
              Text(melted ? '☢' : (broke ? '☕' : '✓'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 46,
                      color: melted ? cRed : (broke ? cViolet : cGreen))),
              const SizedBox(height: 6),
              Text(
                  melted
                      ? 'CORE DESTROYED'
                      : (broke ? 'OPERATOR WALKED OUT' : 'SHIFT COMPLETE'),
                  textAlign: TextAlign.center,
                  style: ts(broke ? 20 : 26,
                      melted ? cRed : (broke ? cViolet : cGreen),
                      w: FontWeight.w900, ls: 3)),
              const SizedBox(height: 6),
              Text(
                melted
                    ? 'Fuel cladding failed and the core is slag. The site is '
                        'being decontaminated — research yield was cut sharply.'
                    : broke
                        ? 'Sanity hit zero. You set down the clipboard, walked '
                            'past the screaming, and did not come back. The '
                            'plant is fine. You are not. Most of the paperwork '
                            'went unfiled.'
                        : 'Plant handed over safely. Everything you generated '
                            'is banked.',
                textAlign: TextAlign.center,
                style: ts(11, cInkDim, w: FontWeight.w500),
              ),
              const SizedBox(height: 20),
              PanelBox(
                child: Column(
                  children: [
                    _row('shift length', mmss(g.reportTime)),
                    _row('energy delivered', '${fmt(g.reportMwh)} MWh'),
                    _row('uranium earned', '⬢ ${fmt(g.reportUranium)}', cGold),
                    _row('research awarded', '◆ ${g.reportResearch}', cViolet),
                    if (melted) _row('damage penalty', '−75% research', cRed),
                    if (broke) _row('unfiled paperwork', '−60% research', cViolet),
                    _row('screams heard', '${g.screamsHeard}', cViolet),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              BigButton(
                label: 'RETURN TO CONTROL BUILDING',
                glyph: '⌂',
                color: cGreen,
                onTap: () {
                  g.sfx.softClick();
                  g.screen = Screen.home;
                  g.bump();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String a, String b, [Color? c]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(a,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(11, cInkDim, w: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(b,
                    maxLines: 1, style: ts(13, c ?? cInk, w: FontWeight.w900)),
              ),
            ),
          ],
        ),
      );
}

// ===========================================================================
// SECTION 17 — manual screen
// ===========================================================================

class ManualScreen extends StatefulWidget {
  const ManualScreen({super.key, required this.game});
  final Game game;

  @override
  State<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends State<ManualScreen> {
  final Speech _speech = Speech();
  int _reading = -1;

  /// Flatten a section into something worth listening to.
  String _spoken(ManualSection s) {
    final b = StringBuffer('${s.title}. ${s.blurb} ');
    for (final e in s.entries) {
      b.write('${e.control}. ${e.text} ');
    }
    return b.toString();
  }

  void _toggle(int i, ManualSection sec) {
    if (_reading == i) {
      _speech.stop();
      setState(() => _reading = -1);
      return;
    }
    _speech.speak(_spoken(sec));
    widget.game.sfx.softClick();
    setState(() => _reading = i);
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canRead = _speech.available;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Row(
                  children: [
                    Text('▥', style: ts(20, cBlue, w: FontWeight.w900)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('OPERATOR MANUAL',
                              style: ts(17, cBlue, w: FontWeight.w900, ls: 2.5)),
                          Text(
                              canRead
                                  ? 'tap ♪ on any page to have it read to you'
                                  : 'every control, what it does, and why',
                              style: ts(9.5, cInkFaint, ls: 1)),
                        ],
                      ),
                    ),
                    _backBtn(widget.game),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 22),
                  itemCount: kManual.length,
                  itemBuilder: (context, i) {
                    final s = kManual[i];
                    final reading = _reading == i;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: PanelBox(
                        border: reading ? cBlue : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(s.title,
                                      style: ts(12, cGreen,
                                          w: FontWeight.w900, ls: 1.6)),
                                ),
                                if (canRead)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _toggle(i, s),
                                    child: Container(
                                      width: 34,
                                      height: 28,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: reading
                                            ? cBlue.withValues(alpha: 0.20)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                            color: reading ? cBlue : cEdge),
                                      ),
                                      child: Text(reading ? '■' : '♪',
                                          style: ts(13,
                                              reading ? cBlue : cInkDim,
                                              w: FontWeight.w900)),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(s.blurb,
                                style: ts(11, cInk, w: FontWeight.w500, ls: 0.1)),
                            const SizedBox(height: 10),
                            for (final e in s.entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 7),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 96,
                                      child: Text(e.control,
                                          style: ts(10, cAmber,
                                              w: FontWeight.w900, ls: 0.8)),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(e.text,
                                          style: ts(10.5, cInkDim,
                                              w: FontWeight.w500, ls: 0.1)),
                                    ),
                                  ],
                                ),
                              ),
                          ],
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

Widget _backBtn(Game g) => GestureDetector(
      onTap: () {
        g.sfx.softClick();
        g.screen = g.shiftActive ? Screen.control : Screen.home;
        g.bump();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: cEdge),
        ),
        child: Text('CLOSE', style: ts(10.5, cInkDim, w: FontWeight.w900)),
      ),
    );

// ===========================================================================
// SECTION 18 — shop screen
// ===========================================================================

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key, required this.game});
  final Game game;

  static const tabs = ['PLANT', 'AI CREW', 'CANTEEN', 'PERMANENT'];

  List<ShopItem> _items(int tab) {
    switch (tab) {
      case 1:
        return kShop.where((e) => e.panel == 'AI CREW').toList();
      case 3:
        return kShop.where((e) => e.research).toList();
      default:
        return kShop
            .where((e) => !e.research && e.panel != 'AI CREW')
            .toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = game;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('PLANT UPGRADES',
                              style: ts(17, cGold, w: FontWeight.w900, ls: 2.5)),
                          Text(
                              '⬢ ${fmt(g.uranium)}   ·   ◆ ${g.research} research',
                              style: ts(10.5, cInkDim, w: FontWeight.w700)),
                        ],
                      ),
                    ),
                    _backBtn(g),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            g.sfx.softClick();
                            g.shopTab = i;
                            g.bump();
                          },
                          child: Container(
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: g.shopTab == i ? cPanel2 : Colors.transparent,
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                  color: g.shopTab == i ? cGold : cEdge),
                            ),
                            child: Text(tabs[i],
                                style: ts(10.5,
                                    g.shopTab == i ? cGold : cInkFaint,
                                    w: FontWeight.w900, ls: 1)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
                  children: [
                    if (g.shopTab == 3)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Research is awarded for megawatt-hours generated and '
                          'survives everything. These upgrades are permanent.',
                          style: ts(10, cInkFaint, w: FontWeight.w500),
                        ),
                      ),
                    if (g.shopTab == 2) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Sanity falls all shift and drops 5 every time the '
                          'building screams. Eat and drink to hold it up — at '
                          'zero you walk out. Stock keeps between shifts.',
                          style: ts(10, cInkFaint, w: FontWeight.w500),
                        ),
                      ),
                      for (final c in kCanteen) _canteenTile(g, c),
                    ] else
                      for (final it in _items(g.shopTab)) _tile(g, it),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _canteenTile(Game g, Consumable c) {
    final afford = g.uranium >= c.cost;
    final have = g.sipsOf(c.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cPanel,
        borderRadius: BorderRadius.circular(9),
        border:
            Border.all(color: afford ? c.color.withValues(alpha: 0.6) : cEdge),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(c.glyph, style: const TextStyle(fontSize: 20)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(11.5, cInk, w: FontWeight.w900)),
                    ),
                    const SizedBox(width: 6),
                    if (have > 0)
                      Text('$have in hand',
                          style: ts(9.5, c.color, w: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(c.tagline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts(10, cInkDim, w: FontWeight.w500, ls: 0.1)),
                const SizedBox(height: 3),
                Text(
                    '${c.sips} ${c.sips == 1 ? "serving" : "sips"} · '
                    '+${c.perSip.round()} each · ${c.total.round()} total',
                    style: ts(8.5, cInkFaint, w: FontWeight.w800, ls: 0.6)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => g.buyConsumable(c),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              decoration: BoxDecoration(
                color: afford
                    ? c.color.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: afford ? c.color : cEdge),
              ),
              child: Text('⬢ ${fmt(c.cost)}',
                  style: ts(11, afford ? c.color : cInkFaint,
                      w: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(Game g, ShopItem it) {
    final level = g.lvl(it.id);
    final maxed = level >= it.maxLevel;
    final cost = it.costAt(level);
    final afford = g.canAfford(it);
    final cur = it.research ? '◆' : '⬢';
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cPanel,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
            color: afford ? it.color.withValues(alpha: 0.6) : cEdge),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: it.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(it.glyph, style: TextStyle(fontSize: 19, color: it.color)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(it.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(11.5, cInk, w: FontWeight.w900)),
                    ),
                    const SizedBox(width: 6),
                    Text(maxed ? 'MAX' : 'LV $level',
                        style: ts(9.5, it.color, w: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(it.desc,
                    style: ts(10, cInkDim, w: FontWeight.w500, ls: 0.1)),
                const SizedBox(height: 3),
                Text(it.panel,
                    style: ts(8.5, cInkFaint, w: FontWeight.w800, ls: 1.2)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: maxed ? null : () => g.buy(it),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              decoration: BoxDecoration(
                color: afford
                    ? it.color.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: afford ? it.color : cEdge),
              ),
              child: Text(
                maxed
                    ? '—'
                    : '$cur ${it.research ? cost.round() : fmt(cost)}',
                style: ts(11, afford ? it.color : cInkFaint,
                    w: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// SECTION 19 — control room
// ===========================================================================

class ControlRoom extends StatelessWidget {
  const ControlRoom({super.key, required this.game});
  final Game game;

  static const tabNames = [
    'REACTIVITY', 'COOLANT', 'STEAM', 'SAFETY', 'ELECTRICAL', 'CREW'
  ];
  static const tabShort = ['RX', 'RCS', 'SEC', 'ESF', 'ELE', 'CREW'];
  static const tabColors = [cGreen, cBlue, cCyan, cRed, cGold, cViolet];

  @override
  Widget build(BuildContext context) {
    final g = game;
    return SafeArea(
      child: LayoutBuilder(builder: (context, box) {
        final tight = box.maxHeight < 660;
        final annH = tight ? 62.0 : 80.0;
        // Measure the fixed chrome first, then split what is actually left
        // between the mimic and the console. Nothing can overflow this way,
        // which is what was causing panels to collide on shorter screens.
        const topH = 46.0, sanH = 26.0, objH = 22.0, tabsH = 72.0, bottomH = 52.0;
        final tutH = g.tutorial ? 54.0 : 0.0;
        final avail =
            math.max(90.0,
                box.maxHeight - (topH + sanH + annH + objH + tabsH + bottomH + tutH));
        final consoleH = clampD(avail * 0.64, 150, 380);
        return Column(
          // Without this the console box shrinks to its content and floats in
          // the middle of the screen instead of spanning the desk.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopStrip(game: g),
            _SanityStrip(game: g),
            SizedBox(
              height: annH,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: AnnunciatorPainter(game: g, repaint: g.frame),
                  size: Size.infinite,
                ),
              ),
            ),
            Expanded(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: PlantViewPainter(game: g, repaint: g.frame),
                  size: Size.infinite,
                ),
              ),
            ),
            _ObjectiveStrip(game: g),
            if (g.tutorial) _TutorialCard(game: g),
            _TabStrip(game: g),
            // Cap the console rather than fixing it: on a wide desk the panel
            // fits in one row and the extra height goes back to the mimic.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: consoleH),
              child: ControlConsole(game: g),
            ),
            _BottomStrip(game: g),
          ],
        );
      }),
    );
  }
}

/// Credits / output / annunciator keys. The live numbers are painted, so this
/// widget only rebuilds when a button is pressed.
class _TopStrip extends StatelessWidget {
  const _TopStrip({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          Expanded(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: TopReadoutPainter(game: g, repaint: g.frame),
                size: Size.infinite,
              ),
            ),
          ),
          _key('ACK', cAmber, () {
            g.plant.ackAlarms();
            g.sfx.clunk(1.3);
            g.bump();
          }),
          _key('SIL', cInkDim, () {
            g.plant.hornSilenced = true;
            g.sfx.clunk(1.5);
            g.bump();
          }),
          _key('RST', cGreen, () {
            g.plant.resetAlarms();
            g.sfx.clunk(1.4);
            g.bump();
          }),
          _LampTestKey(game: g),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              g.sfx.softClick();
              g.screen = Screen.manual;
              g.bump();
            },
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: cBlue.withValues(alpha: 0.6)),
              ),
              child: Text('▤', style: ts(15, cBlue, w: FontWeight.w900)),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _key(String label, Color c, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: c.withValues(alpha: 0.55)),
            ),
            child: Text(label, style: ts(9, c, w: FontWeight.w900, ls: 0.4)),
          ),
        ),
      );
}

class _LampTestKey extends StatefulWidget {
  const _LampTestKey({required this.game});
  final Game game;
  @override
  State<_LampTestKey> createState() => _LampTestKeyState();
}

class _LampTestKeyState extends State<_LampTestKey> {
  @override
  Widget build(BuildContext context) {
    final g = widget.game;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Listener(
        onPointerDown: (_) {
          g.plant.lampTest = true;
          g.sfx.clunk(1.6);
        },
        onPointerUp: (_) => g.plant.lampTest = false,
        onPointerCancel: (_) => g.plant.lampTest = false,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cInk.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: cInkDim.withValues(alpha: 0.5)),
          ),
          child: Text('TEST', style: ts(8, cInkDim, w: FontWeight.w900, ls: 0)),
        ),
      ),
    );
  }
}

/// Sanity, always visible, with the quick sip right next to it. One strip and
/// one button — the whole system costs 26 points of screen.
class _SanityStrip extends StatelessWidget {
  const _SanityStrip({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final pick = g.bestSip();
    return SizedBox(
      height: 26,
      child: Row(
        children: [
          Expanded(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: SanityPainter(game: g, repaint: g.frame),
                size: Size.infinite,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6, left: 4),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (pick == null) {
                  g.sfx.deny();
                  return;
                }
                g.sip(pick);
              },
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: pick == null
                      ? Colors.transparent
                      : cViolet.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                      color: pick == null ? cEdge : cViolet, width: 1),
                ),
                child: Text(
                  pick == null
                      ? 'NO SUPPLIES'
                      : '${canteenItem(pick).glyph} SIP  ${g.totalSips}',
                  style: ts(9, pick == null ? cInkFaint : cViolet,
                      w: FontWeight.w900, ls: 0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The tutorial coach: one step, one sentence on how, and a way out.
class _TutorialCard extends StatelessWidget {
  const _TutorialCard({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final o = nextObjective(g.plant);
    if (o == null) return const SizedBox.shrink();
    final done = kObjectives.where((e) => e.done(g.plant)).length;
    return Container(
      height: 54,
      margin: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      padding: const EdgeInsets.fromLTRB(9, 5, 6, 5),
      decoration: BoxDecoration(
        color: cViolet.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cViolet.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('STEP ${done + 1} OF ${kObjectives.length}',
                    style: ts(7.5, cViolet, w: FontWeight.w900, ls: 1.2)),
                const SizedBox(height: 2),
                Text(o.how,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts(9.5, cInk, w: FontWeight.w600, ls: 0.1)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: g.skipTutorial,
            child: Container(
              width: 46,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cInkFaint),
              ),
              child: Text('SKIP',
                  style: ts(8.5, cInkDim, w: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ObjectiveStrip extends StatelessWidget {
  const _ObjectiveStrip({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: ObjectivePainter(game: game, repaint: game.frame),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Panel selector laid out like the real horseshoe: the three wall panels
/// across the back (SAFETY · REACTIVITY · COOLANT), the two desk wings in
/// front of the operator (SECONDARY · ELECTRICAL).
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.game});
  final Game game;

  // Display order, not storage order: index into ControlRoom.tab* arrays.
  static const backWall = [3, 0, 1];
  static const deskWings = [2, 4, 5];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            for (final i in backWall) ...[
              if (i != backWall.first) const SizedBox(width: 4),
              Expanded(child: _tab(i, tall: true)),
            ],
          ]),
          const SizedBox(height: 4),
          Row(children: [
            for (final i in deskWings) ...[
              if (i != deskWings.first) const SizedBox(width: 4),
              Expanded(child: _tab(i, tall: false)),
            ],
          ]),
        ],
      ),
    );
  }

  Widget _tab(int i, {required bool tall}) {
    final g = game;
    final sel = g.consoleTab == i;
    final c = ControlRoom.tabColors[i];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        g.sfx.softClick();
        g.consoleTab = i;
        g.bump();
      },
      child: Container(
        height: 30,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: sel ? c.withValues(alpha: 0.18) : cPanel,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(tall ? 7 : 3),
            bottom: Radius.circular(tall ? 3 : 7),
          ),
          border: Border.all(color: sel ? c : cEdge, width: sel ? 1.6 : 1),
        ),
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth > 96;
          return FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              wide ? ControlRoom.tabNames[i] : ControlRoom.tabShort[i],
              maxLines: 1,
              style: ts(wide ? 9.5 : 10.5, sel ? c : cInkFaint,
                  w: FontWeight.w900, ls: 0.8),
            ),
          );
        }),
      ),
    );
  }
}

class _BottomStrip extends StatelessWidget {
  const _BottomStrip({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    final p = g.plant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: GuardedButton(
              game: g,
              label: 'SCRAM',
              color: cRed,
              onFire: () {
                p.scram('MANUAL');
                g.bump();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: _flat(
              p.scramLatched ? 'RESET TRIP' : 'TRIP RESET ✓',
              p.scramLatched ? cAmber : cInkFaint,
              () {
                if (p.resetScram()) {
                  g.sfx.clunk(0.8);
                } else {
                  g.sfx.deny();
                }
                g.bump();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: _flat('END SHIFT', cGreen, () {
              g.sfx.chime();
              g.endShift(melted: false);
            }),
          ),
        ],
      ),
    );
  }

  Widget _flat(String label, Color c, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withValues(alpha: 0.65)),
          ),
          child: Text(label, style: ts(11, c, w: FontWeight.w900, ls: 1)),
        ),
      );
}

// ===========================================================================
// SECTION 20 — the five console panels
// ===========================================================================

class ControlConsole extends StatelessWidget {
  const ControlConsole({super.key, required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final g = game;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: cPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: ControlRoom.tabColors[g.consoleTab].withValues(alpha: 0.4)),
      ),
      // Wrapping grid rather than a horizontal strip: every control on the
      // panel stays reachable, which matters when one of them is the MSIV.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _panel(context, g),
        ),
      ),
    );
  }

  List<Widget> _panel(BuildContext context, Game g) {
    switch (g.consoleTab) {
      case 0:
        return _reactivity(context, g);
      case 1:
        return _coolant(context, g);
      case 2:
        return _steam(context, g);
      case 3:
        return _safety(context, g);
      case 4:
        return _electrical(context, g);
      default:
        return _crew(context, g);
    }
  }

  // ---- REACTIVITY ---------------------------------------------------------
  List<Widget> _reactivity(BuildContext context, Game g) {
    final p = g.plant;
    return [
      ControlGroup(label: 'ROD BANK SELECT', children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: PushButton(
                  game: g,
                  label: String.fromCharCode(65 + i),
                  color: cGreen,
                  lit: p.bank == i,
                  latching: true,
                  width: 40,
                  height: 40,
                  onPressed: () {
                    p.bank = i;
                    g.bump();
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 152,
          height: 34,
          child: CustomPaint(
            painter: RodBankPainter(game: g, repaint: g.frame),
          ),
        ),
      ]),
      ControlGroup(label: 'CRDM DRIVE', children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PushButton(
              game: g,
              label: 'IN',
              sub: '▼',
              color: cBlue,
              width: 58,
              height: 50,
              enabled: !p.scrammed && !p.rodAuto,
              lit: p.rodCmd == RodCmd.insert,
              onDown: () => p.rodCmd = RodCmd.insert,
              onUp: () => p.rodCmd = RodCmd.hold,
            ),
            const SizedBox(width: 5),
            PushButton(
              game: g,
              label: 'OUT',
              sub: '▲',
              color: cGreen,
              width: 58,
              height: 50,
              enabled: !p.scrammed && !p.rodAuto,
              lit: p.rodCmd == RodCmd.withdraw,
              onDown: () => p.rodCmd = RodCmd.withdraw,
              onUp: () => p.rodCmd = RodCmd.hold,
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(p.scrammed ? 'RODS TRIPPED — RESET FIRST' : 'SPRING RETURN TO HOLD',
            style: ts(7.5, p.scrammed ? cRed : cInkFaint, ls: 0.4)),
      ]),
      ControlGroup(label: 'CHEMICAL SHIM (BORON)', children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PushButton(
              game: g,
              label: 'BORATE',
              color: cBlue,
              width: 74,
              height: 50,
              lit: p.boronCmd > 0,
              onDown: () => p.boronCmd = 1,
              onUp: () => p.boronCmd = 0,
            ),
            const SizedBox(width: 5),
            PushButton(
              game: g,
              label: 'DILUTE',
              color: cAmber,
              width: 74,
              height: 50,
              lit: p.boronCmd < 0,
              onDown: () => p.boronCmd = -1,
              onUp: () => p.boronCmd = 0,
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'BORON',
              value: (p) => '${p.boron.round()} ppm',
              color: cBlue,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'REACTIVITY / RATE', children: [
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'REACTIVITY',
              value: (p) =>
                  '${p.reactivity >= 0 ? '+' : ''}${p.reactivity.round()} pcm',
              color: cGreen,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'STARTUP RATE',
              value: (p) => '${p.sur >= 0 ? '+' : ''}${p.sur.toStringAsFixed(2)} DPM',
              color: cAmber,
            ),
          ),
        ),
      ]),
      if (g.lvl('autoRod') > 0)
        ControlGroup(label: 'RMCS AUTO', children: [
          PushButton(
            game: g,
            label: 'AUTO ROD',
            lit: p.rodAuto,
            color: cViolet,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
              p.rodAuto = !p.rodAuto;
              g.sfx.clunk();
              g.bump();
            },
          ),
          const SizedBox(height: 6),
          Knob(
            game: g,
            label: 'PWR SETPOINT',
            color: cViolet,
            get: (p) => p.powerSetpoint,
            set: (p, v) => p.powerSetpoint = v,
            unit: '%',
          ),
        ]),
    ];
  }

  /// Usable width inside a control group — the console minus its margins,
  /// padding and borders. Rows of controls size themselves against this so
  /// they cannot overflow a narrow phone.
  static double groupSpace(BuildContext context) =>
      MediaQuery.of(context).size.width - 12 - 18 - 18;

  // ---- COOLANT ------------------------------------------------------------
  List<Widget> _coolant(BuildContext context, Game g) {
    final p = g.plant;
    // Four pump grips have to share one row on every screen down to 320pt.
    final gripW = clampD((groupSpace(context) - 16) / 4, 50, 74);
    return [
      ControlGroup(label: 'REACTOR COOLANT PUMPS', children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: GripSwitch(
                  game: g,
                  label: i < p.pumpsAvailable ? 'RCP ${i + 1}' : 'LOOP ${i + 1}',
                  onLabel: 'RUN',
                  offLabel: 'STOP',
                  value: p.rcp[i],
                  enabled: i < p.pumpsAvailable,
                  width: gripW,
                  height: 66,
                  onChanged: (v) {
                    p.rcp[i] = v;
                    v ? g.sfx.pumpStart() : g.sfx.pumpStop();
                    g.bump();
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'LOOP FLOW',
              value: (p) => '${(p.flow * 100).round()} %',
              color: cBlue,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'PRESSURIZER HEATERS', children: [
        RotarySelector(
          game: g,
          labels: const ['OFF', 'LOW', 'HIGH'],
          value: p.heaters,
          color: cRed,
          onChanged: (v) {
            p.heaters = v;
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'RCS PRESSURE',
              value: (p) => '${p.pressure.toStringAsFixed(1)} bar',
              color: cAmber,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'PZR SPRAY VALVE', children: [
        Knob(
          game: g,
          label: 'SPRAY',
          color: cCyan,
          get: (p) => p.spray,
          set: (p, v) => p.spray = v,
          unit: '%',
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'PZR LEVEL',
              value: (p) => '${p.pzrLevel.round()} %',
              color: cCyan,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'RELIEF', children: [
        GuardedButton(
          game: g,
          label: 'PORV',
          color: cAmber,
          width: 132,
          height: 50,
          latching: true,
          isOn: () => g.plant.porv,
          onFire: () {
            p.porv = !p.porv;
            g.sfx.valve();
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        if (g.lvl('autoPzr') > 0)
          PushButton(
            game: g,
            label: 'PZR AUTO',
            lit: p.pzrAuto,
            color: cViolet,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
              p.pzrAuto = !p.pzrAuto;
              g.sfx.clunk();
              g.bump();
            },
          ),
      ]),
    ];
  }

  // ---- STEAM --------------------------------------------------------------
  List<Widget> _steam(BuildContext context, Game g) {
    final p = g.plant;
    return [
      ControlGroup(label: 'MAIN FEEDWATER', children: [
        Knob(
          game: g,
          label: 'FEED PUMP',
          color: cCyan,
          get: (p) => p.feedPump,
          set: (p, v) => p.feedPump = v,
          unit: '%',
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'SG LEVEL',
              value: (p) => '${p.sgLevel.toStringAsFixed(1)} %',
              color: cCyan,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'FEED REG VALVE', children: [
        PushButton(
            game: g,
            label: p.frvAuto ? 'FRV AUTO' : 'FRV MANUAL',
            lit: p.frvAuto,
            color: cGreen,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
            p.frvAuto = !p.frvAuto;
            g.sfx.clunk();
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        Knob(
          game: g,
          label: 'FRV POSITION',
          color: cGreen,
          enabled: !p.frvAuto,
          get: (p) => p.frvPos,
          set: (p, v) => p.frvPos = v,
          unit: '%',
        ),
      ]),
      ControlGroup(label: 'MAIN STEAM', children: [
        GripSwitch(
          game: g,
          label: 'MSIV',
          onLabel: 'OPEN',
          offLabel: 'SHUT',
          value: p.msiv,
          width: 104,
          height: 66,
          onChanged: (v) {
            p.msiv = v;
            g.sfx.valve();
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'STEAM FLOW',
              value: (p) => '${(p.steamFlow * 100).toStringAsFixed(0)} %',
              color: cInk,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'TURBINE EHC', children: [
        Knob(
          game: g,
          label: 'THROTTLE',
          color: cGold,
          get: (p) => p.throttle,
          set: (p, v) {
            p.throttle = v;
            if (v > 0) p.turbineTripped = false;
          },
          unit: '%',
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'GROSS OUTPUT',
              value: (p) => '${p.mwe.round()} MWe',
              color: cGold,
            ),
          ),
        ),
      ]),
    ];
  }

  // ---- SAFETY -------------------------------------------------------------
  List<Widget> _safety(BuildContext context, Game g) {
    final p = g.plant;
    return [
      ControlGroup(label: 'SAFETY INJECTION', children: [
        GuardedButton(
          game: g,
          label: 'SI ACTUATE',
          color: cRed,
          width: 132,
          height: 50,
          latching: true,
          isOn: () => g.plant.si,
          onFire: () {
            p.si = !p.si;
            g.sfx.valve();
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        Text('floods core, raises\npressure and SG level',
            style: ts(7.5, cInkFaint, ls: 0.2)),
      ]),
      ControlGroup(label: 'CONTAINMENT', children: [
        PushButton(
            game: g,
            label: 'ISOLATION',
            lit: p.contIso,
            color: cRed,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
            p.contIso = !p.contIso;
            g.sfx.clunk(0.8);
            g.bump();
          },
        ),
        const SizedBox(height: 5),
        PushButton(
            game: g,
            label: 'CONT SPRAY',
            lit: p.contSpray,
            color: cCyan,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
            p.contSpray = !p.contSpray;
            g.sfx.valve();
            g.bump();
          },
        ),
      ]),
      ControlGroup(label: 'AUX FEEDWATER', children: [
        PushButton(
            game: g,
            label: 'AFW START',
            lit: p.afw,
            color: cGreen,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
            p.afw = !p.afw;
            g.sfx.pumpStart();
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'CORE DAMAGE',
              value: (p) => '${p.damage.toStringAsFixed(1)} %',
              color: cRed,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'RADIATION', children: [
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'CONTAINMENT',
              value: (p) => '${p.radiation.toStringAsFixed(1)} %',
              color: cAmber,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'XENON',
              value: (p) => '${(p.xenon * 100).round()} %',
              color: cViolet,
            ),
          ),
        ),
      ]),
    ];
  }

  // ---- CREW ---------------------------------------------------------------
  List<Widget> _crew(BuildContext context, Game g) {
    final p = g.plant;
    final owned = kCanteen.where((c) => g.sipsOf(c.id) > 0).toList();
    final bots = const [
      ['autoRod', 'ROD-9'],
      ['autoPzr', 'PZR-4'],
      ['autoTurb', 'SYNC-3'],
      ['feedBot', 'FEED-2'],
      ['watchBot', 'WATCH-1'],
      ['baristaBot', 'BARISTA-B'],
    ].where((b) => g.lvl(b[0]) > 0).toList();

    return [
      ControlGroup(label: 'OPERATOR', children: [
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'SANITY',
              value: (p) => '${p.sanity.round()} %',
              color: cViolet,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'STRESS LOAD',
              value: (p) => '${(p.stress * 100).round()} %',
              color: cAmber,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('screams heard: ${g.screamsHeard}',
            style: ts(8, cInkFaint, w: FontWeight.w600)),
      ]),
      if (owned.isEmpty)
        ControlGroup(label: 'CANTEEN', children: [
          SizedBox(
            width: 148,
            child: Text(
              'Nothing to eat or drink.\nStock up in UPGRADES → CANTEEN '
              'before your next shift.',
              style: ts(9, cInkDim, w: FontWeight.w500, ls: 0.1),
            ),
          ),
        ])
      else
        for (final c in owned)
          ControlGroup(label: c.name, children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(c.glyph, style: TextStyle(fontSize: 22, color: c.color)),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${g.sipsOf(c.id)} left',
                        style: ts(11, c.color, w: FontWeight.w900)),
                    Text('+${c.perSip.round()} each',
                        style: ts(8.5, cInkFaint, w: FontWeight.w700)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            PushButton(
              game: g,
              label: 'SIP',
              color: c.color,
              width: 116,
              height: 40,
              enabled: g.sipsOf(c.id) > 0 && p.sanity < 100,
              onPressed: () => g.sip(c.id),
            ),
          ]),
      ControlGroup(label: 'CANTEEN VENDING', children: [
        SizedBox(
          width: 300,
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final c in kCanteen)
                PushButton(
                  game: g,
                  label: c.glyph,
                  sub: '${c.cost.round()}',
                  color: c.color,
                  width: 46,
                  height: 44,
                  enabled: g.spendable >= c.cost,
                  onPressed: () => g.buyConsumable(c),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 300,
          child: Text(
            'Buy at the desk with tonight\'s earnings. '
            '⬢${fmt(g.spendable)} available.',
            style: ts(8, cInkFaint, w: FontWeight.w600),
          ),
        ),
      ]),
      ControlGroup(label: 'SHIFT LOG', children: [
        SizedBox(
          width: 300,
          height: 96,
          child: g.log.isEmpty
              ? Text('Nothing logged yet.',
                  style: ts(9, cInkFaint, w: FontWeight.w500))
              : ListView.builder(
                  reverse: true,
                  padding: EdgeInsets.zero,
                  itemCount: g.log.length,
                  itemBuilder: (context, i) {
                    final e = g.log[g.log.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.clock,
                              style: ts(8, cInkFaint, w: FontWeight.w700)),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 74,
                            child: Text(e.who,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ts(8, cInkDim, w: FontWeight.w900)),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(e.text,
                                style: ts(8.5, e.color, w: FontWeight.w700)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ]),
      ControlGroup(label: 'CORE / GRID', children: [
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'FUEL BURNUP',
              value: (p) => '${p.burnup.toStringAsFixed(1)} %',
              color: p.burnup > 85 ? cRed : cAmber,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'DISPATCH TARGET',
              value: (p) => '${p.gridDemand.round()} MWe',
              color: cGold,
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'PAY RATE',
              value: (p) => '×${p.dispatchFactor.toStringAsFixed(2)}',
              color: p.dispatchFactor >= 1.2 ? cGreen : cInkDim,
            ),
          ),
        ),
      ]),
      if (bots.isNotEmpty)
        ControlGroup(label: 'AI CREW ON DUTY', children: [
          for (final b in bots)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Lamp(label: b[1], on: true, color: cViolet, width: 148),
            ),
        ]),
    ];
  }

  // ---- ELECTRICAL ---------------------------------------------------------
  List<Widget> _electrical(BuildContext context, Game g) {
    final p = g.plant;
    return [
      ControlGroup(label: 'SYNCHROSCOPE', children: [
        SizedBox(
          width: 92,
          height: 92,
          child: CustomPaint(
            painter: SyncPainter(game: g, repaint: g.frame),
          ),
        ),
      ]),
      ControlGroup(label: 'GENERATOR BREAKER', children: [
        GripSwitch(
          game: g,
          label: 'GEN BKR',
          onLabel: 'CLOSED',
          offLabel: 'OPEN',
          value: p.genBreaker,
          width: 104,
          height: 66,
          onChanged: (v) {
            if (v) {
              final inPhase = math.sin(p.syncAngle).abs() < 0.25;
              if (!inPhase && p.steamFlow > 0.05) {
                // Closing out of phase slams the generator.
                p.damage = clampD(p.damage + 6, 0, 100);
                p.scram('OUT OF PHASE');
                g.shake = math.min(1.0, g.shake + 0.6);
                g.sfx.breaker();
                g.bump();
                return;
              }
              p.genBreaker = true;
              g.sfx.breaker();
            } else {
              p.genBreaker = false;
              g.sfx.clunk(0.7);
            }
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'TO GRID',
              value: (p) => '${p.mwe.round()} MWe',
              color: cGold,
            ),
          ),
        ),
      ]),
      ControlGroup(label: 'EMERGENCY DIESEL', children: [
        PushButton(
            game: g,
            label: 'EDG START',
            lit: p.edg,
            color: cAmber,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
            p.edg = !p.edg;
            p.edg ? g.sfx.pumpStart() : g.sfx.pumpStop();
            g.bump();
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 148,
          height: 26,
          child: CustomPaint(
            painter: ReadoutPainter(
              game: g,
              repaint: g.frame,
              label: 'URANIUM RATE',
              value: (p) => '⬢ ${fmt(p.mwe * p.uraniumPrice)}/s',
              color: cGold,
            ),
          ),
        ),
      ]),
      if (g.lvl('autoTurb') > 0)
        ControlGroup(label: 'EHC AUTOSYNC', children: [
          PushButton(
            game: g,
            label: 'AUTO SYNC',
            lit: p.syncAuto,
            color: cViolet,
            latching: true,
            width: 148,
            height: 40,
            onPressed: () {
              p.syncAuto = !p.syncAuto;
              g.sfx.clunk();
              g.bump();
            },
          ),
        ]),
    ];
  }
}

class ControlGroup extends StatelessWidget {
  const ControlGroup({super.key, required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
      decoration: BoxDecoration(
        color: cPanel2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: cEdge),
      ),
      // IntrinsicWidth keeps each group only as wide as its widest control, so
      // the Wrap can pack several groups per row instead of one per line.
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: ts(7.5, cInkFaint, w: FontWeight.w900, ls: 1.1)),
            const SizedBox(height: 5),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// SECTION 21 — physical control hardware
// ===========================================================================
// Every control on the console is a real object: it has a bezel, a face that
// travels when you press it, a shadow that collapses as it goes down, and a
// lamp. Presses are driven by an AnimationController handed straight to the
// painter as its `repaint` listenable — the motion is smooth and costs zero
// widget rebuilds, which is why nothing here feels sticky.

/// Shared press mechanics: pointer capture, travel animation, latch state.
///
/// Pointer capture matters more than it sounds. A finger that slides off a
/// button still owns the pointer, so the release always lands here rather than
/// leaving a control stuck down — the old console's worst habit.
abstract class PressableState<T extends StatefulWidget> extends State<T>
    with SingleTickerProviderStateMixin {
  late final AnimationController press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: const Duration(milliseconds: 150),
  );

  bool _down = false;

  bool get latched => false;
  bool get enabled => true;

  /// How far the face is depressed, 0..1.
  double get depth => math.max(press.value, latched ? 1.0 : 0.0);

  void onPressDown() {}
  void onPressUp() {}
  void onPressCancel() => onPressUp();

  @override
  void dispose() {
    // If this control is torn down mid-press (tab switch, shift end) the
    // release would never arrive, so deliver it now. This is what stops rods
    // driving forever after you change panels while holding OUT.
    if (_down) {
      _down = false;
      onPressCancel();
    }
    press.dispose();
    super.dispose();
  }

  void handleDown() {
    if (!enabled) {
      onPressDown();
      return;
    }
    _down = true;
    press.forward();
    onPressDown();
  }

  void handleUp() {
    if (!_down) return;
    _down = false;
    press.reverse();
    onPressUp();
  }

  void handleCancel() {
    if (!_down) return;
    _down = false;
    press.reverse();
    onPressCancel();
  }

  Widget pressable({required Widget child}) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => handleDown(),
        onPointerUp: (_) => handleUp(),
        onPointerCancel: (_) => handleCancel(),
        child: child,
      );
}

// ---------------------------------------------------------------------------
// Lighted pushbutton — the square plunger that snaps
// ---------------------------------------------------------------------------

class PushButton extends StatefulWidget {
  const PushButton({
    super.key,
    required this.game,
    required this.label,
    required this.color,
    this.sub,
    this.lit = false,
    this.latching = false,
    this.enabled = true,
    this.width = 86,
    this.height = 46,
    this.onPressed,
    this.onDown,
    this.onUp,
  });

  final Game game;
  final String label;
  final String? sub;
  final Color color;

  /// Internal lamp on — for latching controls this is also the depressed look.
  final bool lit;
  final bool latching;
  final bool enabled;
  final double width;
  final double height;

  /// Fired on release for ordinary buttons.
  final VoidCallback? onPressed;

  /// Momentary controls (rod drives, boron) use these instead.
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  @override
  State<PushButton> createState() => _PushButtonState();
}

class _PushButtonState extends PressableState<PushButton> {
  @override
  bool get latched => widget.latching && widget.lit;

  @override
  bool get enabled => widget.enabled;

  @override
  void onPressDown() {
    if (!widget.enabled) {
      widget.game.sfx.deny();
      return;
    }
    widget.game.sfx.clunk(widget.latching ? 0.9 : 1.1);
    widget.onDown?.call();
  }

  @override
  void onPressUp() {
    if (!widget.enabled) return;
    if (widget.onUp != null) {
      widget.game.sfx.clunkUp(1.1);
      widget.onUp!.call();
    }
    widget.onPressed?.call();
  }

  @override
  void onPressCancel() {
    if (!widget.enabled) return;
    // A cancelled press releases the hardware but must not count as a click.
    widget.onUp?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: widget.latching ? widget.lit : null,
      label: widget.sub == null ? widget.label : '${widget.label} ${widget.sub}',
      child: pressable(
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CustomPaint(
          painter: PushButtonPainter(
            repaint: press,
            state: this,
            label: widget.label,
            sub: widget.sub,
            color: widget.color,
            lit: widget.lit,
            enabled: widget.enabled,
          ),
        ),
      ),
      ),
    );
  }
}

class PushButtonPainter extends CustomPainter {
  PushButtonPainter({
    required Listenable repaint,
    required this.state,
    required this.label,
    required this.sub,
    required this.color,
    required this.lit,
    required this.enabled,
  }) : super(repaint: repaint);

  final PressableState state;
  final String label;
  final String? sub;
  final Color color;
  final bool lit;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final d = state.depth;
    final c = enabled ? color : cInkFaint;
    const travel = 3.0;

    // Recess the button sits in.
    final well = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(7));
    canvas.drawRRect(well, Paint()..color = const Color(0xFF080B10));
    canvas.drawRRect(
      well,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF303B47),
    );

    // Cast shadow shrinks as the face travels down.
    final faceRect = Rect.fromLTWH(
        3, 2 + travel * d, size.width - 6, size.height - 5 - travel * d);
    if (d < 0.98) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            faceRect.translate(0, travel * (1 - d)), const Radius.circular(5)),
        Paint()..color = Colors.black.withValues(alpha: 0.55 * (1 - d)),
      );
    }

    // Face.
    final face = RRect.fromRectAndRadius(faceRect, const Radius.circular(5));
    final glow = lit ? 1.0 : 0.0;
    canvas.drawRRect(
      face,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(const Color(0xFF39434F), c, 0.20 + 0.45 * glow)!
                .withValues(alpha: 1),
            Color.lerp(const Color(0xFF212932), c, 0.10 + 0.30 * glow)!,
          ],
        ).createShader(faceRect),
    );

    // Bevel: bright top edge, dark bottom edge. Both fade as it is pressed in.
    final bevel = (1 - d * 0.75).clamp(0.0, 1.0).toDouble();
    canvas.drawLine(
      Offset(faceRect.left + 4, faceRect.top + 1),
      Offset(faceRect.right - 4, faceRect.top + 1),
      Paint()
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.16 * bevel),
    );
    canvas.drawLine(
      Offset(faceRect.left + 4, faceRect.bottom - 1),
      Offset(faceRect.right - 4, faceRect.bottom - 1),
      Paint()
        ..strokeWidth = 1.4
        ..color = Colors.black.withValues(alpha: 0.45 * bevel),
    );
    canvas.drawRRect(
      face,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lit ? 1.5 : 1
        ..color = lit
            ? c.withValues(alpha: 0.95)
            : c.withValues(alpha: enabled ? 0.45 : 0.2),
    );
    if (lit) {
      canvas.drawRRect(
        face.inflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = c.withValues(alpha: 0.22),
      );
    }

    // Legend, engraved into the face so it travels with it.
    final textColor = enabled
        ? (lit ? Color.lerp(Colors.white, c, 0.25)! : cInk)
        : cInkFaint;
    final hasSub = sub != null && sub!.isNotEmpty;
    canvas.save();
    canvas.clipRRect(face);
    drawText(
      canvas,
      label,
      Offset(faceRect.center.dx, faceRect.center.dy - (hasSub ? 9 : 5)),
      size: size.height < 34 ? 8.5 : 10,
      color: textColor,
      align: TextAlign.center,
      weight: FontWeight.w900,
      ls: 0.7,
      maxWidth: faceRect.width - 4,
    );
    if (hasSub) {
      drawText(
        canvas,
        sub!,
        Offset(faceRect.center.dx, faceRect.center.dy + 3),
        size: 8,
        color: enabled ? c : cInkFaint,
        align: TextAlign.center,
        weight: FontWeight.w800,
        maxWidth: faceRect.width - 4,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PushButtonPainter old) =>
      old.lit != lit || old.enabled != enabled || old.label != label;
}

// ---------------------------------------------------------------------------
// Guarded pushbutton — red, under a hinged flip cover
// ---------------------------------------------------------------------------

class GuardedButton extends StatefulWidget {
  const GuardedButton({
    super.key,
    required this.game,
    required this.label,
    required this.color,
    required this.onFire,
    this.width = 150,
    this.height = 50,
    this.latching = false,
    this.isOn,
  });

  final Game game;
  final String label;
  final Color color;
  final VoidCallback onFire;
  final double width;
  final double height;
  final bool latching;
  final bool Function()? isOn;

  @override
  State<GuardedButton> createState() => _GuardedButtonState();
}

class _GuardedButtonState extends State<GuardedButton>
    with TickerProviderStateMixin {
  late final AnimationController lid = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final AnimationController press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 80),
    reverseDuration: const Duration(milliseconds: 150),
  );
  double openedAt = -99;

  /// Armed the instant the cover is tapped, independent of the animation —
  /// a fast double-tap in an emergency must still fire.
  bool isOpen = false;

  @override
  void dispose() {
    lid.dispose();
    press.dispose();
    super.dispose();
  }

  void _tap() {
    final g = widget.game;
    if (!isOpen) {
      isOpen = true;
      lid.forward();
      openedAt = g.t;
      g.sfx.clunk(0.7);
      return;
    }
    press.forward().then((_) {
      if (mounted) press.reverse();
    });
    widget.onFire();
    if (!widget.latching) {
      isOpen = false;
      lid.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.isOn?.call() ?? false;
    // The cover falls shut by itself if you hesitate.
    if (isOpen && !on && widget.game.t - openedAt > 6) {
      isOpen = false;
      lid.reverse();
    }
    return Semantics(
      button: true,
      label: isOpen
          ? 'Guard open, press to fire ${widget.label}'
          : '${widget.label}, guarded',
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CustomPaint(
          painter: GuardedButtonPainter(
            repaint: Listenable.merge([lid, press, widget.game.frame]),
            lid: lid,
            press: press,
            label: widget.label,
            color: widget.color,
            on: on,
          ),
        ),
      ),
      ),
    );
  }
}

class GuardedButtonPainter extends CustomPainter {
  GuardedButtonPainter({
    required Listenable repaint,
    required this.lid,
    required this.press,
    required this.label,
    required this.color,
    required this.on,
  }) : super(repaint: repaint);

  final Animation<double> lid;
  final Animation<double> press;
  final String label;
  final Color color;
  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final o = Curves.easeOutBack.transform(lid.value.clamp(0.0, 1.0));
    final d = press.value;

    final well =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(well, Paint()..color = const Color(0xFF080B10));
    canvas.drawRRect(
      well,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: 0.35 + 0.4 * o),
    );

    // Mushroom head.
    final cx = size.width * 0.5;
    final cy = size.height * 0.5 + 2 * d;
    final r = math.min(size.width, size.height) * 0.30;
    if (d < 0.9) {
      canvas.drawCircle(Offset(cx, cy + 2.5 * (1 - d)), r,
          Paint()..color = Colors.black.withValues(alpha: 0.5 * (1 - d)));
    }
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.5),
          colors: [
            Color.lerp(color, Colors.white, on ? 0.45 : 0.30)!,
            color,
            Color.lerp(color, Colors.black, 0.45)!,
          ],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r)),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.black.withValues(alpha: 0.5),
    );
    if (on) {
      canvas.drawCircle(Offset(cx, cy), r + 3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = color.withValues(alpha: 0.3));
    }

    // Legend to the right of the head.
    drawText(canvas, on ? '$label ON' : label, Offset(cx + r + 8, cy - 6),
        size: 11,
        color: color,
        weight: FontWeight.w900,
        ls: 1,
        maxWidth: size.width - (cx + r + 12));

    // Hinged cover, swinging up and out of the way.
    if (o < 0.995) {
      final lift = o;
      canvas.save();
      canvas.translate(0, -size.height * 0.92 * lift);
      final coverRect =
          Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
      final cover =
          RRect.fromRectAndRadius(coverRect, const Radius.circular(6));
      canvas.drawRRect(
          cover,
          Paint()
            ..color = const Color(0xFF161C24)
                .withValues(alpha: (1 - lift * 0.25).clamp(0.0, 1.0)));
      // Hazard stripes.
      canvas.save();
      canvas.clipRRect(cover);
      final stripe = Paint()
        ..color = color.withValues(alpha: 0.85 * (1 - lift * 0.4))
        ..strokeWidth = 5;
      for (var i = -2; i < size.width / 9 + 3; i++) {
        canvas.drawLine(
          Offset(coverRect.left + i * 9, coverRect.bottom),
          Offset(coverRect.left + i * 9 + coverRect.height, coverRect.top),
          stripe,
        );
      }
      canvas.restore();
      canvas.drawRRect(
        cover,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: (1 - lift * 0.3).clamp(0.0, 1.0)),
      );
      // Legend plate on the cover so a shut guard still says what it fires.
      final plateW = math.min(coverRect.width - 16, label.length * 11.0 + 22);
      final plate = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: coverRect.center, width: plateW, height: 22),
        const Radius.circular(4),
      );
      canvas.drawRRect(
          plate,
          Paint()
            ..color = const Color(0xFF0B0F14)
                .withValues(alpha: (0.92 - lift * 0.4).clamp(0.0, 1.0)));
      canvas.drawRRect(
        plate,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: (0.8 - lift * 0.4).clamp(0.0, 1.0)),
      );
      drawText(canvas, label, Offset(coverRect.center.dx, coverRect.center.dy - 7),
          size: 12,
          color: color.withValues(alpha: (1 - lift * 0.5).clamp(0.0, 1.0)),
          align: TextAlign.center,
          weight: FontWeight.w900,
          ls: 1.6,
          maxWidth: plateW - 4);
      // Hinge pins along the top edge.
      for (var i = 0; i < 2; i++) {
        canvas.drawCircle(
          Offset(size.width * (i == 0 ? 0.22 : 0.78), 4),
          2.2,
          Paint()..color = const Color(0xFF6C7885),
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant GuardedButtonPainter old) =>
      old.on != on || old.label != label;
}

// ---------------------------------------------------------------------------
// J-handle / pistol-grip selector
// ---------------------------------------------------------------------------

class GripSwitch extends StatefulWidget {
  const GripSwitch({
    super.key,
    required this.game,
    required this.label,
    required this.value,
    required this.onChanged,
    this.onLabel = 'ON',
    this.offLabel = 'OFF',
    this.enabled = true,
    this.width = 92,
    this.height = 62,
  });

  final Game game;
  final String label;
  final String onLabel;
  final String offLabel;
  final bool value;
  final bool enabled;
  final double width;
  final double height;
  final ValueChanged<bool> onChanged;

  @override
  State<GripSwitch> createState() => _GripSwitchState();
}

class _GripSwitchState extends State<GripSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.value ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant GripSwitch old) {
    super.didUpdateWidget(old);
    // Follow the plant, not just our own taps — an auto-trip throws the handle.
    if (widget.value != (turn.value > 0.5)) {
      widget.value ? turn.forward() : turn.reverse();
    }
  }

  @override
  void dispose() {
    turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: widget.value,
      label: '${widget.label}, '
          '${widget.value ? widget.onLabel : widget.offLabel}',
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!widget.enabled) {
          widget.game.sfx.deny();
          return;
        }
        widget.onChanged(!widget.value);
      },
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CustomPaint(
          painter: GripSwitchPainter(
            repaint: turn,
            turn: turn,
            label: widget.label,
            onLabel: widget.onLabel,
            offLabel: widget.offLabel,
            enabled: widget.enabled,
          ),
        ),
      ),
      ),
    );
  }
}

class GripSwitchPainter extends CustomPainter {
  GripSwitchPainter({
    required Listenable repaint,
    required this.turn,
    required this.label,
    required this.onLabel,
    required this.offLabel,
    required this.enabled,
  }) : super(repaint: repaint);

  final Animation<double> turn;
  final String label;
  final String onLabel;
  final String offLabel;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOutBack.transform(turn.value.clamp(0.0, 1.0));
    // Red for energised, green for open — the real console colour code.
    final c = !enabled
        ? cInkFaint
        : (turn.value > 0.5 ? const Color(0xFFFF5A4D) : const Color(0xFF4BE08A));

    final plate =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7));
    canvas.drawRRect(plate, Paint()..color = const Color(0xFF10161D));
    canvas.drawRRect(
      plate,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = c.withValues(alpha: 0.5),
    );

    final cx = size.width / 2;
    final cy = size.height * 0.42;
    final r = math.min(size.width, size.height) * 0.26;

    // Escutcheon with detent marks.
    canvas.drawCircle(
        Offset(cx, cy), r * 1.5, Paint()..color = const Color(0xFF1A222B));
    for (var i = 0; i < 2; i++) {
      final a = i == 0 ? -math.pi * 0.75 : -math.pi * 0.25;
      canvas.drawLine(
        Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * (r * 1.15),
        Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * (r * 1.45),
        Paint()
          ..strokeWidth = 1.5
          ..color = cInkFaint,
      );
    }

    // The handle itself, swinging between detents.
    final ang = lerpD(-math.pi * 0.75, -math.pi * 0.25, t);
    final tip = Offset(cx, cy) + Offset(math.cos(ang), math.sin(ang)) * r * 1.5;
    canvas.drawLine(
      Offset(cx, cy),
      tip,
      Paint()
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = Colors.black.withValues(alpha: 0.5),
    );
    canvas.drawLine(
      Offset(cx, cy),
      tip,
      Paint()
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = c,
    );
    // Ball end of the J-handle.
    canvas.drawCircle(
      tip,
      4.5,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          colors: [Color.lerp(c, Colors.white, 0.6)!, c],
        ).createShader(Rect.fromCircle(center: tip, radius: 4.5)),
    );
    // Boss.
    canvas.drawCircle(Offset(cx, cy), r * 0.42,
        Paint()..color = const Color(0xFF2A343F));
    canvas.drawCircle(
      Offset(cx, cy),
      r * 0.42,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black54,
    );

    drawText(canvas, label, Offset(cx, size.height - 22),
        size: 7.5,
        color: cInkFaint,
        align: TextAlign.center,
        ls: 0.9,
        maxWidth: size.width - 4);
    drawText(canvas, turn.value > 0.5 ? onLabel : offLabel,
        Offset(cx, size.height - 13),
        size: 9.5,
        color: c,
        align: TextAlign.center,
        weight: FontWeight.w900,
        maxWidth: size.width - 4);
  }

  @override
  bool shouldRepaint(covariant GripSwitchPainter old) =>
      old.enabled != enabled ||
      old.label != label ||
      old.onLabel != onLabel ||
      old.offLabel != offLabel;
}

// ---------------------------------------------------------------------------
// Rotary selector — several fixed detents
// ---------------------------------------------------------------------------

class RotarySelector extends StatefulWidget {
  const RotarySelector({
    super.key,
    required this.game,
    required this.labels,
    required this.value,
    required this.color,
    required this.onChanged,
    this.caption,
    this.width = 108,
    this.height = 66,
  });

  final Game game;
  final List<String> labels;
  final int value;
  final Color color;
  final String? caption;
  final double width;
  final double height;
  final ValueChanged<int> onChanged;

  @override
  State<RotarySelector> createState() => _RotarySelectorState();
}

class _RotarySelectorState extends State<RotarySelector>
    with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: widget.labels.length < 2
        ? 0
        : widget.value / (widget.labels.length - 1),
  );

  @override
  void didUpdateWidget(covariant RotarySelector old) {
    super.didUpdateWidget(old);
    if (widget.labels.length > 1) {
      spin.animateTo(widget.value / (widget.labels.length - 1),
          curve: Curves.easeOutBack);
    }
  }

  @override
  void dispose() {
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        // Tap a detent label to go straight there; tap the knob to advance.
        final w = widget.width / widget.labels.length;
        final i = (d.localPosition.dx / w).floor();
        final next = d.localPosition.dy > widget.height * 0.62
            ? i.clamp(0, widget.labels.length - 1)
            : (widget.value + 1) % widget.labels.length;
        widget.game.sfx.clunk(1 + next * 0.12);
        widget.onChanged(next);
      },
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CustomPaint(
          painter: RotaryPainter(
            repaint: spin,
            spin: spin,
            labels: widget.labels,
            value: widget.value,
            color: widget.color,
            caption: widget.caption,
          ),
        ),
      ),
    );
  }
}

class RotaryPainter extends CustomPainter {
  RotaryPainter({
    required Listenable repaint,
    required this.spin,
    required this.labels,
    required this.value,
    required this.color,
    required this.caption,
  }) : super(repaint: repaint);

  final Animation<double> spin;
  final List<String> labels;
  final int value;
  final Color color;
  final String? caption;

  @override
  void paint(Canvas canvas, Size size) {
    final plate =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7));
    canvas.drawRRect(plate, Paint()..color = const Color(0xFF10161D));
    canvas.drawRRect(
      plate,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = cEdge,
    );

    final cx = size.width / 2;
    final cy = size.height * 0.40;
    final r = math.min(size.width * 0.5, size.height * 0.40) * 0.62;

    // Detent ticks fanned across the top.
    const spread = math.pi * 0.72;
    for (var i = 0; i < labels.length; i++) {
      final f = labels.length < 2 ? 0.5 : i / (labels.length - 1);
      final a = -math.pi / 2 - spread / 2 + spread * f;
      final sel = i == value;
      canvas.drawLine(
        Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * (r * 1.25),
        Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * (r * 1.6),
        Paint()
          ..strokeWidth = sel ? 2.4 : 1.2
          ..color = sel ? color : cInkFaint,
      );
    }

    // Knurled knob.
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.6),
          colors: [const Color(0xFF48545F), const Color(0xFF232B34)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r)),
    );
    for (var i = 0; i < 18; i++) {
      final a = i * math.pi / 9;
      canvas.drawLine(
        Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * (r * 0.82),
        Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * r,
        Paint()
          ..strokeWidth = 1
          ..color = Colors.black.withValues(alpha: 0.35),
      );
    }
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.black.withValues(alpha: 0.6),
    );

    // Pointer, animated between detents.
    final a = -math.pi / 2 - spread / 2 + spread * spin.value;
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx, cy) + Offset(math.cos(a), math.sin(a)) * r * 0.95,
      Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    // Detent legends along the bottom, the selected one lit.
    final w = size.width / labels.length;
    for (var i = 0; i < labels.length; i++) {
      drawText(canvas, labels[i], Offset(w * (i + 0.5), size.height - 13),
          size: 8,
          color: i == value ? color : cInkFaint,
          align: TextAlign.center,
          weight: i == value ? FontWeight.w900 : FontWeight.w700,
          maxWidth: w - 2);
    }
    if (caption != null) {
      drawText(canvas, caption!, Offset(cx, 2),
          size: 7,
          color: cInkFaint,
          align: TextAlign.center,
          maxWidth: size.width - 4);
    }
  }

  @override
  bool shouldRepaint(covariant RotaryPainter old) =>
      old.value != value || old.color != color;
}

// ---------------------------------------------------------------------------
// Hand-indicating controller — the drag bar
// ---------------------------------------------------------------------------

/// Kept exactly as it behaves today (drag anywhere along the track, tap to
/// jump) because it is the control that already feels right; only the
/// hardware around it got rebuilt.
class Knob extends StatefulWidget {
  const Knob({
    super.key,
    required this.game,
    required this.label,
    required this.color,
    required this.get,
    required this.set,
    this.unit = '%',
    this.enabled = true,
    this.width = 148,
  });

  final Game game;
  final String label;
  final Color color;
  final double Function(Plant) get;
  final void Function(Plant, double) set;
  final String unit;
  final bool enabled;
  final double width;

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double _acc = 0;
  bool _dragging = false;

  void _apply(double dx) {
    final p = widget.game.plant;
    widget.set(p, clampD(widget.get(p) + dx * 0.62, 0, 100));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.enabled ? widget.color : cInkFaint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        if (!widget.enabled) return;
        _acc = 0;
        setState(() => _dragging = true);
      },
      onHorizontalDragUpdate: (d) {
        if (!widget.enabled) return;
        _apply(d.delta.dx);
        _acc += d.delta.dx.abs();
        if (_acc > 13) {
          _acc = 0;
          widget.game.sfx.softClick();
        }
      },
      onHorizontalDragEnd: (_) => setState(() => _dragging = false),
      onHorizontalDragCancel: () => setState(() => _dragging = false),
      onTapDown: (d) {
        if (!widget.enabled) {
          widget.game.sfx.deny();
          return;
        }
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        widget.set(widget.game.plant,
            clamp01(d.localPosition.dx / box.size.width) * 100);
        widget.game.sfx.clunk(1.2);
      },
      child: SizedBox(
        width: widget.width,
        height: 52,
        child: CustomPaint(
          painter: KnobPainter(
            game: widget.game,
            repaint: widget.game.frame,
            label: widget.label,
            unit: widget.unit,
            color: c,
            get: widget.get,
            dragging: _dragging,
          ),
        ),
      ),
    );
  }
}

class KnobPainter extends GamePainter {
  KnobPainter({
    required super.game,
    required super.repaint,
    required this.label,
    required this.unit,
    required this.color,
    required this.get,
    required this.dragging,
  });

  final String label;
  final String unit;
  final Color color;
  final double Function(Plant) get;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final v = get(plant);

    final plate =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7));
    canvas.drawRRect(plate, Paint()..color = const Color(0xFF10161D));
    canvas.drawRRect(
      plate,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dragging ? 1.6 : 1
        ..color = dragging ? color : cEdge,
    );

    drawText(canvas, label, const Offset(7, 5),
        size: 7.5, color: cInkFaint, ls: 0.9, maxWidth: size.width - 60);
    drawText(canvas, '${v.toStringAsFixed(0)}$unit', Offset(size.width - 7, 3),
        size: 12,
        color: color,
        align: TextAlign.right,
        weight: FontWeight.w900,
        maxWidth: 56);

    // Sunken track.
    final track = Rect.fromLTWH(8, 22, size.width - 16, 14);
    final trackR = RRect.fromRectAndRadius(track, const Radius.circular(7));
    canvas.drawRRect(trackR, Paint()..color = const Color(0xFF070A0E));
    canvas.drawRRect(
      trackR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black,
    );

    canvas.save();
    canvas.clipRRect(trackR);
    final fillW = track.width * clamp01(v / 100);
    if (fillW > 1) {
      canvas.drawRect(
        Rect.fromLTWH(track.left, track.top, fillW, track.height),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.75),
              color.withValues(alpha: 0.35),
            ],
          ).createShader(track),
      );
    }
    // Scale marks every 10%.
    for (var i = 1; i < 10; i++) {
      final x = track.left + track.width * i / 10;
      canvas.drawLine(
        Offset(x, track.top + 3),
        Offset(x, track.bottom - 3),
        Paint()
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.10),
      );
    }
    canvas.restore();

    // Sliding handle with a grip line, exactly where the finger is.
    final hx = clampD(track.left + fillW, track.left + 7, track.right - 7);
    final handle = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(hx, track.center.dy),
          width: dragging ? 16 : 13,
          height: 26),
      const Radius.circular(4),
    );
    canvas.drawRRect(handle.shift(const Offset(0, 1.5)),
        Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRRect(
      handle,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, 0.45)!, color],
        ).createShader(handle.outerRect),
    );
    for (var i = -1; i <= 1; i++) {
      canvas.drawLine(
        Offset(hx + i * 3.0, track.center.dy - 6),
        Offset(hx + i * 3.0, track.center.dy + 6),
        Paint()
          ..strokeWidth = 1
          ..color = Colors.black.withValues(alpha: 0.3),
      );
    }

    drawText(canvas, dragging ? 'ADJUSTING' : 'DRAG OR TAP',
        Offset(size.width / 2, size.height - 12),
        size: 6.5,
        color: dragging ? color : cInkFaint.withValues(alpha: 0.7),
        align: TextAlign.center,
        maxWidth: size.width - 8);
  }
}

// ---------------------------------------------------------------------------
// Indicator lamp
// ---------------------------------------------------------------------------

class Lamp extends StatelessWidget {
  const Lamp({
    super.key,
    required this.label,
    required this.on,
    required this.color,
    this.width = 108,
  });

  final String label;
  final bool on;
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 26,
      child: CustomPaint(
        painter: LampPainter(label: label, on: on, color: color),
      ),
    );
  }
}

class LampPainter extends CustomPainter {
  LampPainter({required this.label, required this.on, required this.color});
  final String label;
  final bool on;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final r = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(5));
    canvas.drawRRect(r, Paint()..color = const Color(0xFF10161D));
    canvas.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = on ? color.withValues(alpha: 0.7) : cEdge,
    );
    final c = Offset(13, size.height / 2);
    if (on) {
      canvas.drawCircle(c, 9, Paint()..color = color.withValues(alpha: 0.25));
    }
    canvas.drawCircle(
      c,
      5,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          colors: on
              ? [Color.lerp(color, Colors.white, 0.7)!, color]
              : [const Color(0xFF2A333D), const Color(0xFF161D25)],
        ).createShader(Rect.fromCircle(center: c, radius: 5)),
    );
    drawText(canvas, label, Offset(26, size.height / 2 - 5),
        size: 8.5,
        color: on ? color : cInkDim,
        weight: FontWeight.w800,
        maxWidth: size.width - 30);
  }

  @override
  bool shouldRepaint(covariant LampPainter old) =>
      old.on != on || old.label != label;
}

// ===========================================================================
// SECTION 22 — painters
// ===========================================================================

/// Every painter takes the frame notifier as `repaint`, so a frame costs paint
/// only — no rebuild, no layout.
abstract class GamePainter extends CustomPainter {
  GamePainter({required this.game, required Listenable repaint})
      : super(repaint: repaint);
  final Game game;
  Plant get plant => game.plant;

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class TopReadoutPainter extends GamePainter {
  TopReadoutPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final p = plant;
    // Never draw past our own box — the annunciator keys sit immediately right.
    canvas.clipRect(Offset.zero & size);

    final total = game.uranium + p.uraniumThisShift;
    // The four SPDS safety pillars need 124px; give them the right-hand side
    // only when the readout still has room to breathe.
    const spdsW = 124.0;
    final showSpds = size.width > 250;
    final textW = (showSpds ? size.width - spdsW : size.width) - 14;

    drawText(canvas, '⬢ ${fmt(total)}', const Offset(10, 4),
        size: 16, color: cGold, weight: FontWeight.w900, maxWidth: textW);
    // What the grid asked for, and what you are actually sending.
    final onLoad = p.dispatchError < 0.06 && p.mwe > 0;
    drawText(
      canvas,
      '${p.iMwe.round()} / ${p.gridDemand.round()} MWe',
      const Offset(10, 23),
      size: 10,
      color: p.mwe <= 0 ? cInkDim : (onLoad ? cGreen : cAmber),
      weight: FontWeight.w800,
      maxWidth: textW,
    );
    drawText(
      canvas,
      '${game.clockText}  ·  ${p.rangeName}  ·  FUEL ${p.burnup.round()}%',
      const Offset(10, 35),
      size: 7.5,
      color: p.burnup > 85 ? cAmber : cInkFaint,
      maxWidth: textW,
    );

    if (!showSpds) return;
    final labels = ['RX', 'CLG', 'RCS', 'CTMT'];
    final vals = [
      p.spdsReactivity,
      p.spdsCooling,
      p.spdsIntegrity,
      p.spdsContainment
    ];
    var x = size.width - spdsW + 2;
    for (var i = 0; i < 4; i++) {
      final v = vals[i];
      final c = v > 0.66 ? cGreen : (v > 0.33 ? cAmber : cRed);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 10, 24, 6), const Radius.circular(3)),
        Paint()..color = cEdge,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 10, 24 * clamp01(v), 6), const Radius.circular(3)),
        Paint()..color = c,
      );
      drawText(canvas, labels[i], Offset(x + 12, 19),
          size: 7, color: cInkFaint, align: TextAlign.center, maxWidth: 30);
      x += 30;
    }
  }
}

class SanityPainter extends GamePainter {
  SanityPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final p = plant;
    final v = clamp01(p.sanity / 100);
    final low = p.sanity < 30;
    // Colour walks from calm violet to alarm red as the operator frays.
    final c = p.sanity > 60
        ? cViolet
        : (p.sanity > 30 ? cAmber : cRed);

    drawText(canvas, 'SANITY', const Offset(8, 3),
        size: 7, color: cInkFaint, ls: 1.2, maxWidth: 60);

    final track = Rect.fromLTWH(8, 13, size.width - 62, 8);
    final tr = RRect.fromRectAndRadius(track, const Radius.circular(4));
    canvas.drawRRect(tr, Paint()..color = const Color(0xFF080B10));
    canvas.save();
    canvas.clipRRect(tr);
    canvas.drawRect(
      Rect.fromLTWH(track.left, track.top, track.width * v, track.height),
      Paint()
        ..shader = LinearGradient(
          colors: [c.withValues(alpha: 0.55), c],
        ).createShader(track),
    );
    canvas.restore();
    canvas.drawRRect(
      tr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = low
            ? c.withValues(
                alpha: clampD(0.5 + 0.5 * math.sin(game.t * 8), 0, 1))
            : cEdge,
    );

    drawText(canvas, '${p.sanity.round()}', Offset(size.width - 6, 5),
        size: 11,
        color: c,
        align: TextAlign.right,
        weight: FontWeight.w900,
        maxWidth: 46);

    // The jolt right after a scream.
    if (game.screamFlash > 0.01) {
      final a = clampD(game.screamFlash, 0, 1);
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = cRed.withValues(alpha: 0.28 * a),
      );
      drawText(canvas, '— 5  ??', Offset(size.width / 2, 5),
          size: 10,
          color: cRed.withValues(alpha: a),
          align: TextAlign.center,
          weight: FontWeight.w900,
          maxWidth: size.width);
    }
  }
}

class ObjectivePainter extends GamePainter {
  ObjectivePainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final p = plant;

    // A fresh log line takes the strip for a few seconds — the room talking to
    // you — then it hands back to the checklist.
    if (game.logFlash > 0 && game.log.isNotEmpty) {
      final e = game.log.last;
      final fade = clampD(game.logFlash / 0.8, 0, 1);
      drawText(canvas, '${e.clock}  ${e.who}', const Offset(8, 5),
          size: 8, color: cInkFaint.withValues(alpha: fade), maxWidth: 150);
      drawText(canvas, e.text, Offset(size.width - 8, 4),
          size: 9.5,
          color: e.color.withValues(alpha: fade),
          align: TextAlign.right,
          weight: FontWeight.w800,
          maxWidth: size.width - 168);
      return;
    }

    final o = nextObjective(p);
    if (p.damage > 0.5) {
      final pulse = 0.6 + 0.4 * math.sin(game.t * 6);
      drawText(
          canvas,
          '⚠  CORE DAMAGE ${p.damage.toStringAsFixed(1)}%  —  reduce fuel temperature '
          'or SCRAM',
          Offset(size.width / 2, 4),
          size: 10,
          color: cRed.withValues(alpha: clampD(pulse, 0, 1)),
          align: TextAlign.center,
          maxWidth: size.width - 12);
      return;
    }
    if (o == null) {
      drawText(canvas, 'PLANT AT POWER — hold it steady and bank the megawatts',
          Offset(size.width / 2, 5),
          size: 9.5, color: cGreen, align: TextAlign.center);
      return;
    }
    drawText(canvas, '▸  ${o.text}', Offset(size.width / 2, 5),
        size: 9.5,
        color: cInkDim,
        align: TextAlign.center,
        maxWidth: size.width - 12);
  }
}

class AnnunciatorPainter extends GamePainter {
  AnnunciatorPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final p = plant;
    const cols = 5;
    final rows = (kAlarms.length / cols).ceil();
    const padX = 6.0;
    const gap = 3.0;
    final tw = (size.width - padX * 2 - gap * (cols - 1)) / cols;
    final th = (size.height - 8 - gap * (rows - 1)) / rows;
    final blink = (game.t * 2.6) % 1 < 0.55;

    for (var i = 0; i < kAlarms.length; i++) {
      final a = kAlarms[i];
      final st = p.alarms[a.id] ?? AlarmState.clear;
      final r = Rect.fromLTWH(
        padX + (i % cols) * (tw + gap),
        4 + (i ~/ cols) * (th + gap),
        tw,
        th,
      );
      final base = a.critical ? cRed : cAmber;
      var lit = false;
      var bright = 0.0;
      if (p.lampTest) {
        lit = true;
        bright = 1;
      } else if (st == AlarmState.flashing) {
        lit = blink;
        bright = blink ? 1 : 0.25;
      } else if (st == AlarmState.acked) {
        lit = true;
        bright = 0.72;
      }

      final rr = RRect.fromRectAndRadius(r, const Radius.circular(3));
      canvas.drawRRect(
        rr,
        Paint()
          ..color = lit
              ? Color.lerp(cPanel, base, 0.30 * bright)!
              : const Color(0xFF10151C),
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lit ? 1.4 : 1
          ..color = lit
              ? base.withValues(alpha: clampD(0.55 + 0.45 * bright, 0, 1))
              : cEdge,
      );
      if (lit && bright > 0.6) {
        canvas.drawRRect(
          rr.inflate(1.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = base.withValues(alpha: clampD(0.22 * bright, 0, 1)),
        );
      }
      final tc = lit
          ? Color.lerp(cInk, base, 0.35 * bright)!
          : cInkFaint.withValues(alpha: 0.5);
      final fs = th < 17 ? 5.6 : 6.4;
      canvas.save();
      canvas.clipRRect(rr);
      drawText(canvas, a.l1, Offset(r.center.dx, r.top + th * 0.18),
          size: fs, color: tc, align: TextAlign.center, ls: 0.2, maxWidth: tw);
      drawText(canvas, a.l2, Offset(r.center.dx, r.top + th * 0.52),
          size: fs, color: tc, align: TextAlign.center, ls: 0.2, maxWidth: tw);
      canvas.restore();
    }
  }
}

/// The plant mimic: core, loops, meters. Everything here is live.
class PlantViewPainter extends GamePainter {
  PlantViewPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final p = plant;
    final w = size.width;
    final h = size.height;
    // Clip so nothing this painter draws can ever bleed into a neighbour.
    canvas.clipRect(Offset.zero & size);
    if (h < 40) return;

    // ---- edgewise meter columns -------------------------------------------
    const mw = 58.0;
    _meters(canvas, Rect.fromLTWH(2, 2, mw, h - 4), [
      _M('FLUX', p.iFlux / 9.5, '${p.iFlux.toStringAsFixed(1)} dec', cGreen),
      _M('T-FUEL', clamp01(p.iFuelT / 1400), '${p.iFuelT.round()} °C', cRed),
      _M('T-AVG', clamp01(p.iTavg / 360), '${p.iTavg.round()} °C', cAmber),
    ]);
    _meters(canvas, Rect.fromLTWH(w - mw - 2, 2, mw, h - 4), [
      _M('RCS', clamp01(p.iPress / 200), '${p.iPress.round()} bar', cBlue),
      _M('SG LVL', clamp01(p.iSg / 100), '${p.iSg.round()} %', cCyan),
      _M('OUTPUT', clamp01(p.iMwe / math.max(1, p.ratedMWe)),
          '${p.iMwe.round()} MW', cGold),
    ]);

    // ---- core mimic --------------------------------------------------------
    final cx = w / 2;
    // Reserve a strip at the bottom for the status caption so the vessel can
    // never grow over it.
    const captionH = 16.0;
    final cy = (h - captionH) / 2;
    // The hazard ring reaches 1.2x the vessel radius, so the caption has to
    // clear that — not just the vessel — or it prints straight through it.
    final base = math.min((w - mw * 2 - 24) * 0.5, (h - captionH) * 0.38);
    if (base < 18) return;

    final hot = Color.lerp(cGreen, const Color(0xFFFF5A1F),
        clamp01((p.fuelTemp - 250) / 900))!;
    final glowPower = clamp01(p.power / 1.1);

    // glow scales with actual neutron power
    if (glowPower > 0.001) {
      final gr = base * (1.35 + 0.5 * glowPower);
      canvas.drawCircle(
        Offset(cx, cy),
        gr,
        Paint()
          ..shader = RadialGradient(colors: [
            hot.withValues(alpha: clampD(0.42 * glowPower + 0.05, 0, 1)),
            hot.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: gr)),
      );
    }

    // vessel
    canvas.drawCircle(
      Offset(cx, cy),
      base,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = const Color(0xFF283340),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      base * 0.88,
      Paint()..color = const Color(0xFF0E141B),
    );

    // fuel region
    canvas.drawCircle(
      Offset(cx, cy),
      base * 0.72,
      Paint()
        ..shader = RadialGradient(colors: [
          Color.lerp(hot, Colors.white, 0.35 * glowPower)!,
          hot.withValues(alpha: clampD(0.25 + 0.7 * glowPower, 0, 1)),
          const Color(0xFF121A22),
        ], stops: const [
          0,
          0.55,
          1
        ]).createShader(
            Rect.fromCircle(center: Offset(cx, cy), radius: base * 0.72)),
    );

    // control rods drawn at their true insertion depth
    final rodTop = cy - base * 0.95;
    for (var i = 0; i < 4; i++) {
      final rx = cx + (i - 1.5) * base * 0.30;
      final ins = 1 - p.rod[i] / 100; // 1 = fully inserted
      final len = base * 1.35 * ins;
      canvas.drawLine(
        Offset(rx, rodTop),
        Offset(rx, rodTop + len),
        Paint()
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = i == p.bank ? cGreen : const Color(0xFF5A6775),
      );
      if (i == p.bank) {
        canvas.drawCircle(Offset(rx, rodTop - 4), 2.6, Paint()..color = cGreen);
      }
    }

    // coolant loops — dashes animate with real flow
    final flowPhase = game.t * (0.4 + p.flow * 2.4);
    for (var side = 0; side < 2; side++) {
      final dir = side == 0 ? -1 : 1;
      final r = base * 1.18;
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = (p.pumpCount > 0 ? cBlue : cInkFaint)
            .withValues(alpha: p.pumpCount > 0 ? 0.75 : 0.25);
      for (var i = 0; i < 7; i++) {
        final a0 = dir * (flowPhase + i * 0.42) + (side == 0 ? math.pi : 0);
        canvas.drawArc(rect, a0, 0.22, false, paint);
      }
    }

    // steam plume when the secondary is actually running
    if (p.steamFlow > 0.02) {
      final n = (p.steamFlow * 14).clamp(1, 14).toInt();
      for (var i = 0; i < n; i++) {
        final ph = (game.t * 0.6 + i / n) % 1;
        final yy = cy - base * 1.0 - ph * base * 0.7;
        final rr = 3 + ph * 11;
        canvas.drawCircle(
          Offset(cx + math.sin(ph * 5 + i) * 14, yy),
          rr,
          Paint()
            ..color = Colors.white
                .withValues(alpha: clampD(0.16 * (1 - ph) * p.steamFlow * 2, 0, 1)),
        );
      }
    }

    // status caption
    final label = p.scrammed
        ? 'REACTOR TRIPPED — ${p.scramCause}'
        : (p.power > 0.05 ? 'REACTOR AT POWER' : 'REACTOR CRITICAL — LOW POWER');
    drawText(canvas, label,
        Offset(cx, math.min(cy + base * 1.30 + 4, h - 12)),
        size: 8.5,
        color: p.scrammed ? cRed : cGreen,
        align: TextAlign.center,
        ls: 1.6,
        maxWidth: w - mw * 2 - 12);
  }

  void _meters(Canvas canvas, Rect area, List<_M> ms) {
    final hEach = area.height / ms.length;
    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final r = Rect.fromLTWH(area.left, area.top + i * hEach, area.width, hEach - 4);
      if (r.height < 26) continue;
      final track = Rect.fromLTWH(r.left + 4, r.top + 14, r.width - 8, r.height - 28);
      canvas.drawRect(track, Paint()..color = const Color(0xFF0D1219));
      canvas.drawRect(
        Rect.fromLTWH(track.left, track.bottom - track.height * clamp01(m.v),
            track.width, track.height * clamp01(m.v)),
        Paint()..color = m.c.withValues(alpha: 0.85),
      );
      // scale ticks
      final tick = Paint()
        ..color = cInkFaint.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      for (var k = 1; k < 5; k++) {
        final y = track.bottom - track.height * k / 5;
        canvas.drawLine(Offset(track.left, y), Offset(track.left + 4, y), tick);
      }
      canvas.drawRect(
        track,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = cEdge,
      );
      drawText(canvas, m.label, Offset(r.center.dx, r.top + 1),
          size: 7,
          color: cInkFaint,
          align: TextAlign.center,
          ls: 0.8,
          maxWidth: r.width);
      drawText(canvas, m.text, Offset(r.center.dx, r.bottom - 11),
          size: 8.5, color: m.c, align: TextAlign.center, maxWidth: r.width);
    }
  }
}

class _M {
  const _M(this.label, this.v, this.text, this.c);
  final String label;
  final double v;
  final String text;
  final Color c;
}

class ReadoutPainter extends GamePainter {
  ReadoutPainter({
    required super.game,
    required super.repaint,
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String Function(Plant) value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(4)),
      Paint()..color = const Color(0xFF0B1017),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = cEdge,
    );
    drawText(canvas, label, const Offset(6, 3),
        size: 6.5, color: cInkFaint, ls: 0.9);
    drawText(canvas, value(plant), Offset(size.width - 6, 10),
        size: 11, color: color, align: TextAlign.right, weight: FontWeight.w900);
  }
}

class RodBankPainter extends GamePainter {
  RodBankPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final p = plant;
    final rowH = size.height / 4;
    for (var i = 0; i < 4; i++) {
      final y = i * rowH;
      final sel = p.bank == i;
      drawText(canvas, String.fromCharCode(65 + i), Offset(0, y + 0.5),
          size: 7.5, color: sel ? cGreen : cInkFaint);
      final track = Rect.fromLTWH(12, y + 1.5, size.width - 44, rowH - 4);
      canvas.drawRect(track, Paint()..color = const Color(0xFF0B1017));
      canvas.drawRect(
        Rect.fromLTWH(12, y + 1.5, (size.width - 44) * p.rod[i] / 100, rowH - 4),
        Paint()..color = (sel ? cGreen : cInkDim).withValues(alpha: 0.75),
      );
      canvas.drawRect(
        track,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = cEdge,
      );
      drawText(canvas, '${p.rod[i].round()}%', Offset(size.width, y + 0.5),
          size: 7.5, color: sel ? cGreen : cInkDim, align: TextAlign.right);
    }
  }
}

class SyncPainter extends GamePainter {
  SyncPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final p = plant;
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 - 4;

    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF0B1017));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = cEdge,
    );
    // the in-phase window at twelve o'clock
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r - 3),
      -math.pi / 2 - 0.26,
      0.52,
      true,
      Paint()..color = cGreen.withValues(alpha: 0.18),
    );
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * (r - 4),
        c + Offset(math.cos(a), math.sin(a)) * r,
        Paint()
          ..strokeWidth = 1
          ..color = cInkFaint,
      );
    }
    final inPhase = math.sin(p.syncAngle).abs() < 0.25;
    final needle = p.syncAngle - math.pi / 2;
    final col = p.genBreaker ? cInkFaint : (inPhase ? cGreen : cAmber);
    canvas.drawLine(
      c,
      c + Offset(math.cos(needle), math.sin(needle)) * (r - 6),
      Paint()
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = col,
    );
    canvas.drawCircle(c, 3, Paint()..color = col);
    drawText(
      canvas,
      p.genBreaker ? 'ON GRID' : (inPhase ? 'IN PHASE' : 'SLIPPING'),
      Offset(c.dx, size.height - 11),
      size: 7.5,
      color: col,
      align: TextAlign.center,
    );
  }
}

class GripPainter extends CustomPainter {
  GripPainter({required this.on, required this.color});
  final bool on;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    canvas.drawCircle(c, r * 0.92, Paint()..color = const Color(0xFF222B35));
    canvas.drawCircle(
      c,
      r * 0.92,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: 0.8),
    );
    // J-handle points up-left when off, up-right when on
    final a = on ? -math.pi / 4 : -math.pi * 3 / 4;
    final tip = c + Offset(math.cos(a), math.sin(a)) * r * 0.78;
    canvas.drawLine(
      c,
      tip,
      Paint()
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    canvas.drawCircle(tip, 2.4, Paint()..color = color);
    canvas.drawCircle(c, r * 0.22, Paint()..color = const Color(0xFF10161D));
  }

  @override
  bool shouldRepaint(covariant GripPainter old) =>
      old.on != on || old.color != color;
}

class GuardPainter extends CustomPainter {
  GuardPainter({required this.open, required this.color});
  final bool open;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(r.deflate(2), const Radius.circular(3)),
      Paint()..color = color.withValues(alpha: open ? 0.85 : 0.25),
    );
    if (!open) {
      // closed flip cover: hatched lid across the button
      final p = Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = 1.6;
      for (var i = -2; i < 4; i++) {
        canvas.drawLine(
          Offset(2.0 + i * 5, size.height - 2),
          Offset(2.0 + i * 5 + size.height, -2),
          p,
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.deflate(1), const Radius.circular(3)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant GuardPainter old) =>
      old.open != open || old.color != color;
}

class FxPainter extends GamePainter {
  FxPainter({required super.game, required super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final origin = size.center(Offset.zero);
    for (final p in game.particles) {
      final lf = clamp01(p.life / p.maxLife);
      final pos = origin + p.pos;
      switch (p.kind) {
        case 0:
          canvas.drawCircle(pos, p.size * (0.5 + 0.5 * lf),
              Paint()..color = p.color.withValues(alpha: lf));
        case 1:
          canvas.drawCircle(pos, p.size * (1.7 - 0.7 * lf),
              Paint()..color = p.color.withValues(alpha: lf * 0.22));
        case 2:
          canvas.save();
          canvas.translate(pos.dx, pos.dy);
          canvas.rotate(p.rot);
          final r = Rect.fromCenter(
              center: Offset.zero, width: p.size, height: p.size * 0.7);
          canvas.drawRect(r, Paint()..color = p.color.withValues(alpha: lf));
          canvas.restore();
        case 3:
          canvas.drawCircle(
            pos,
            p.size + (1 - lf) * 150,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1 + 4 * lf
              ..color = p.color.withValues(alpha: lf * 0.8),
          );
      }
    }
  }
}
