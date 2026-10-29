# Motion, effects and performance

Battleships animates everything: the sea lives, shells fly, ships sink, the HUD counts. All of it
is driven by one *motion policy* that reads the phone's settings and state, so the game stays
smooth, accessible and cool to the touch. This page is for testers and for anyone tuning it.

## The three tiers

Every effect asks the policy which tier it is in before it moves.

| Tier | When | What you see |
| --- | --- | --- |
| **Full** | The default on a phone that is awake, cool and not in Low Power Mode | Everything: living water, shell flights, particles, screen shake, flashes, shaders, parallax |
| **Reduced** | Low Power Mode, a warm phone (thermal state *serious*), Effects = Reduced, or 45 seconds idle on your turn | Half the ambient frame rate, no shake or flashes, shorter sequences, sea and shaders still drawn |
| **Still** | Reduce Motion, VoiceOver, Effects = Minimal, a critically hot phone, or the app in the background | Nothing moves on its own; state changes crossfade; openings and finales collapse to a short fade with every control available at once |

Besides the tier, the policy carries a few switches:

- **Flashes** draw only when the Flashes setting is on *and* iOS's Dim Flashing Lights is off.
- **Screen shake** draws only when its setting is on and Reduce Motion is off.
- **Shaders** (the Metal water, ripples, rain, chromatic split) stop only when the phone is
  critically hot; in the still tier they draw a frozen frame.
- **Frame rate** is capped at 60 in the full tier and 30 below it, and never above the screen's
  own rate. A ProMotion display's 120 Hz is never used for effects.

## The settings

**Profile → Effects** has the controls a player can reach:

- **Effects**: Full, Reduced or Minimal. Reduced is for an older phone or a long session;
  Minimal is the still tier on demand.
- **Screen Shake** and **Flashes**: off for anyone they bother. Flashes also follow iOS's
  *Accessibility → Motion → Dim Flashing Lights*.
- **Haptic Strength**: Off, Light, Medium or Strong. Core Haptics plays a composed score when the
  phone has it; older phones get the UIKit generators.
- **Ambient Sound**: the sea under the lobby and the battle, while Sound Effects are on.

The preview at the top of the screen is a patch of the real battle water, so a change shows at
once.

iOS settings the app follows without being asked: Reduce Motion, VoiceOver, Dim Flashing Lights,
Low Power Mode, and the thermal state.

## Reading the performance overlay

Development and TestFlight builds have a frame-time overlay for testers. Open **Profile** and tap
the **Version** row five times; tap five times again to hide it. (An App Store build has no hidden
gesture.)

The overlay shows three lines, refreshed once a second:

```
8.4 ms avg · 19 ms worst
dropped 0/s · 6 timelines
full tier · nominal · 60 Hz screen
```

- **avg / worst**: the average and the longest frame in the last second. 16.7 ms is a full frame
  at 60 Hz; an average near that with a worst of 30 or more means the screen is stuttering.
- **dropped**: frames that took over one and a half times the display's interval. A few during a
  sinking or a finale are expected; a steady count while nothing is happening is a bug.
- **timelines**: how many clocks are ticking right now (water, particles, cue sheets, loops).
  At rest the budget is 3 to 5 on an iPhone battle screen (up to 7 while a shell lands), 3 in the
  lobby, 2 on the game-over card and 1 on a sheet. More than that usually means something kept
  animating off screen.
- **tier · thermal · screen**: the policy's tier, the phone's thermal state (nominal, fair,
  serious, critical) and the display's refresh rate.

### What to report

If the game feels slow, note the three lines, which screen you were on and what had just
happened (a sinking, a finale, a rematch). The thermal state matters: on a hot phone the app
drops a tier on purpose, and that is working as designed. Dropped frames on a cool phone in the
full tier are what we want to hear about, with the phone model and iOS version.

## How it stays cheap

- **One clock per surface.** A screen's effects share a timeline rather than each view running its
  own `TimelineView`. The battle's water, particles and shell flights tick from the board's
  effects layer; the lobby's sea from one loop.
- **Pause when covered.** A sheet stills the screen beneath it; the app's going to the background
  freezes every clock; a battle that sits idle for 45 seconds drops to the reduced tier until the
  player touches it again.
- **Particles are plain data.** Bursts are generated deterministically from a seed and drawn in a
  single `Canvas`, so a hit costs one draw call, not a view per spark.
- **Shaders warm up at launch.** Every Metal shader is drawn once, off screen, when the app
  starts, so the first hit of a game never stalls on pipeline compilation.
- **Screenshots and tests pin the clocks.** The screenshot tests freeze every clock at a known
  phase and fix the sky palette to daylight, so CI's images compare run to run.

## Measuring on a device

Before a release, run Instruments' Core Animation and Energy templates on an older phone (an A13
iPhone such as the SE 2 or iPhone 11) and on a ProMotion phone, through a full game against the
computer, a five-minute wait on the opponent's turn and a finale. The targets: no sustained dropped
frames at rest, at most one dropped frame per landing on the A13, the energy gauge at Low during the
wait, and a thermal state never above fair in a twenty-minute session. Record the numbers here.

| Date | Phone | iOS | At rest | At a landing | Idle energy | Thermal | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

## Verifying motion in CI

The iOS job records the simulator while the tests run and uploads `motion-video` beside the
`screenshots` artifact. The filmstrip tests play each sequence between a magenta title card and a
green end card, so the video can be cut into strips per sequence. The tests snapshot nothing while a
sequence plays: a snapshot of the window takes the main thread for up to a second on the simulator,
which would stall the very motion being recorded. Instead `filmstrips/timeline.txt` in the
`screenshots` artifact gives, for every strip, the Unix time of its title card, its action and its
end, and every stall of the main thread a watchdog saw while it played, relative to the action:

```
battle-hit 2.6s start=1793291061.53 state=0 scenes=1
  battle-hit action=1793291063.78 end=1793291066.39 state=0 stalls=+0.02s:0.14s
```

`build/recording-start.txt` in the video artifact says when the recording began, so a strip's
frames can be lined up with its timeline to within a frame. A stall over 100 ms while a shot
lands is worth a look; a stall during a strip's first frames is the screen being built. One still of
each strip's final frame is saved as `filmstrips/<strip>/final.jpg`. The acceptance criteria for
each sequence are in the design spec.
