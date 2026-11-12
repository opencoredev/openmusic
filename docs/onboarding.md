# First run

The first-run flow every OpenMusic app shows once, on a fresh install: Welcome, Your music, Sync, Approve this device,
then Home. The steps and words are the same on Mac, iPhone and Windows; the look is each platform's own.

## Steps

1. **Welcome.** The icon, "OpenMusic", "YouTube Music and Spotify in one fast player, on all your devices." and
   **Get Started**.
2. **Your music.** YouTube Music: **Sign in with Google** (the existing YouTube sign-in) or **Use without an account**
   (signed-out YouTube Music browses and plays). Spotify: **Connect** (the existing flow), "Playback needs Spotify
   Premium" in small text, optional. Each service is marked done with its account name once it succeeded.
   **Continue** works once at least one service is ready; signed-out YouTube Music counts.
3. **Sync (optional).** "Pick up where you left off." **Continue with Apple**, **Continue with Google**, or an email
   address and **Send Code** (a 6-digit code in one field; pasting "123 456" works; a wrong code empties the field and
   says why; Resend Code after 30 s). Under it: "OpenMusic's server sees when you play and pause, never what you play.
   Songs, queues and searches are encrypted on your devices." **Use your own server** opens one address field;
   **Check** shows the answer in place (checking, "Reachable and set up", or the exact problem) before **Use This
   Server** switches. A new check replaces one still running. **Not Now** goes to Home.
4. **Approve this device**, only when the account already has a device holding the sign-in key: "Open OpenMusic on
   your Mac to approve this iPhone" (the noun is the holder's platform), the six-digit code large, **Codes Match** /
   **Codes Don't Match**, and **Do This Later** (the app works; a quiet banner stays until this device is approved).
   Waiting, allowed, denied and failed each say what happened and what to do (Ask Again). The first device of an
   account never sees this step.
5. **Done.** Home, already loading underneath. When another device plays, the "Continue from …" banner is there.

Later, every step is in Settings: Account (sync, server, devices, sign out) and Accounts/Services (YouTube Music,
Spotify). Settings › General › "Show Again…" opens the flow on the Mac.

## When it shows

`FirstRun.shouldShow` (`Sources/OpenMusicSync/FirstRun.swift`), decided at launch from local state only, before any
network: shown on a fresh install; not shown once `firstRunFinished` is set (finishing or skipping sets it, and a
version bump doesn't clear it), not for an install that answered the welcome sheets before it (`didShowAccountWelcome`,
`didOnboard`), and not when a YouTube Music or Spotify sign-in was restored (an iPhone reinstall keeps its Keychain).
Finishing also sets the two old keys, so an older build run afterwards stays quiet. Where to go after a sign-in
follows the key status (`FirstRun.afterSignIn`): Approve this device while the account has another holder, Home
otherwise.

## Mac and iPhone

- Mac (`Sources/OpenMusic/Onboarding/`): `FirstRunFlow` holds the state; `FirstRunView` covers the whole main window in
  the manner of Setup Assistant (symbol, title and line at the top, a narrow column, Back bottom-left, the step's
  action bottom-right). The split view underneath is disabled and hidden from VoiceOver, and the toolbar hides, while
  it shows. Return is the step's action, Escape its way past (Not Now, Do This Later) or Back, ⌘[ Back. Transitions go
  through `Motion.Transition.firstRunForward`/`firstRunBack` (a crossfade with Reduce Motion). The window's minimum
  (900 × 560) gets a compact header and a scrolling column. The service sign-ins are the existing sheets
  (`AppModel.signInRequest`).
- iPhone (`iOS/OpenMusic/Onboarding/`): a full-screen cover with a navigation stack (swipe back works; Approve has no
  Back). Liquid Glass buttons (`.glassProminent` for the step's action), Continue with Apple in Apple's black (white in
  dark mode) style. At accessibility text sizes the buttons scroll with the page instead of sitting in the bottom bar.
- Do This Later sets `firstRunApprovalDeferred`; the hub shows a quiet "Approve this Mac/iPhone" banner in the
  player's banner slot (a Continue banner wins) until the key arrives or the account signs out. Its Approve… opens
  Settings › Account, which has Codes Match.
- Continue with Apple and Google go through Clerk's web OAuth (`oauth_apple`, `oauth_google`) in an
  `ASWebAuthenticationSession`, back through `openmusic://oauth-callback`. Native Sign in with Apple would need the
  Sign in with Apple entitlement, which the current signing profile can't carry ([accounts design](accounts-design.md#clerk-on-native-the-decision)).

## Checking it

`scripts/onboarding-shots-apple.sh` runs both Apple apps through every step live and captures each one ([maintainers](maintainers.md#first-run-flow)); `scripts/windows-council-shots.sh --only onboarding` does the same for Windows.
