# Air Traffic Control — game concept and implementation plan

**20 November 2026 traffic-rule update:** Inbound/holding/approach aircraft now fly faster until touchdown; all non-landing airborne traffic shares one altitude; airborne aircraft that enter collision vicinity are lost with a score penalty; ground-service vehicles pass through aircraft footprints without waiting.

**20 November 2026 runway-phase update:** Point5 is implemented. Live flights now use distinct line-up, takeoff-roll, landing-roll and runway-exit phases. Physical runway strips are separate from package-defined operating ends with explicit threshold, direction, hold, exit and usable length. Delhi keeps its current four enabled directions. See [PROTOTYPE.md](PROTOTYPE.md#operational-phases-and-runway-end-data-20-november-2026).

**20 November 2026 motion-model update:** Point4 is implemented. Ground planning, scheduled execution, unscheduled runway/escape movement and safety lookahead now share one phase-aware model for cruise speed, acceleration, braking, reaction allowance, turning rate and clearance uncertainty. See [PROTOTYPE.md](PROTOTYPE.md#calibrated-ground-motion-model-20-november-2026) and [PROJECT_MEMORY.md](PROJECT_MEMORY.md) for verification and limits.

**20 November 2026 airport-package update:** Point2 is implemented. Airport geometry, identity, operations, traffic and service inventories now load from versioned data packages with separate simulation contexts. Delhi remains the default. See [AIRPORT_PACKAGES.md](AIRPORT_PACKAGES.md) for the schema and verification.

**20 November 2026 routing update:** Ordinary ground traffic now uses a shared safe-interval planner with timed movements, waits and swept aircraft-footprint reservations. ATC crossing and runway authority remain explicit. See [PROTOTYPE.md](PROTOTYPE.md#shared-timed-ground-planner-20-november-2026) and [PROJECT_MEMORY.md](PROJECT_MEMORY.md) for scope, verification and remaining proposals.

**19 November 2026 update:** The playable Swift/SpriteKit prototype now uses a fixed photographic background from the user’s Expanded Delhi Airport Satellite Terrain.png, with aligned aircraft, all four runways, immediate live clearances, collision recovery and 16 native ground service roles, nine gates including Terminal 1, fixed pixel taxiways and timed arrival-to-departure turnarounds. Open `AirTrafficControl.xcodeproj`; see [PROTOTYPE.md](PROTOTYPE.md) for play instructions, verified checks and current limitations. The original concept below is preserved as historical design context, including proposals that are not implemented.

Recorded: 18 November 2026. Working project name; no final game title selected.

## 1. Project status and user requirements

The user selected an air traffic control style game after discussing monetizable game ideas. They want to understand development for both iPad and MacBook, payments, Apple commission, and use of their existing Stripe account and UK bank account. They have Apple Developer Program membership.

This folder saves the concept and proposed implementation for later development. No playable game, Xcode project, payment integration, revenue validation or App Store submission has been implemented. Technology and monetization choices below are recommendations from the discussion, not separately approved purchases or final commercial decisions.

## 2. Core game idea

Players operate an airport approach radar and guide arriving aircraft into landing sequences while managing departures. They select aircraft and assign headings, altitude bands, speed and holding instructions. Aircraft differ in speed and manoeuvrability. Players maintain separation, avoid conflicts and keep the runway flowing.

The central challenge is deciding which aircraft should land next and creating a safe route for it while the rest of the airspace keeps moving. Clear command previews, visible aircraft intent and understandable conflict feedback should make mistakes feel fair. This is an entertainment game, not an operational aviation or controller-training product.

The first playable version should contain one fictional airport, two runways, a small set of aircraft types, arrival/departure sequencing, separation detection, scoring, pause/save and a short tutorial. Offer short shifts and an endless mode once the basic loop works. Suggested later additions are weather, runway closures, limited-fuel emergencies and airports with genuinely different layouts; these are not required for the first prototype.

Airport ground control, railway junction dispatch, harbour control and spaceport control were related ideas. Keep the initial project focused on air traffic control.

## 3. Proposed Apple implementation

Use Xcode and Swift, with SpriteKit for the 2D radar scene and aircraft animation, SwiftUI for menus/settings and StoreKit 2 for App Store purchases. Share the simulation and game rules between iPadOS and macOS, with separate platform input handling and layouts where needed.

Suggested responsibilities:

- **Game model:** aircraft, runways, airport boundaries, waypoints, active commands and shift state.
- **Simulation:** movement, heading/speed/altitude transitions, aircraft spawning, runway occupancy, separation checks and scoring. Keep rules independent of rendering so they can be tested.
- **Presentation:** radar, labels, selection, route/command previews and conflict warnings.
- **Input:** touch selection and gestures on iPad; mouse, trackpad and keyboard on Mac. Both issue the same game commands.
- **Persistence:** versioned local saves, settings and best scores. Pause appropriately when the app becomes inactive and avoid large simulation jumps on return.
- **Purchases:** verified entitlements for a full-game unlock and any future airport packs, separate from the simulation.

Use consistent world coordinates and convert to screen coordinates so resizing or zooming does not alter the simulation. Keep the first version offline and avoid adding accounts, multiplayer, servers or runtime AI unless a later requirement needs them. Establish a bounded aircraft count and profile a busy airport before introducing complex optimizations.

## 4. Implementation sequence and acceptance checks

1. **Playable prototype:** one radar scene, selectable moving aircraft, a heading command and successful landing. Completion means the basic interaction is enjoyable and repeatable on an actual device.
2. **Complete game loop:** add spawning, altitude/speed commands, departures, runway occupancy, separation rules, scoring, failure/restart and tutorial. Test deterministic scenarios, crossing trajectories and simultaneous runway requests. Separate visual warnings from actual rule decisions.
3. **iPad and Mac controls:** test touch hit targets, overlapping aircraft selection, mouse/keyboard actions, resizing and zooming. Preserve selection and aircraft state across layout changes; do not rely solely on colour for aircraft status or warnings.
4. **Save and interruption handling:** verify pause/resume, background/foreground, save/load, malformed saves and a long interrupted shift. Simulation speed and scoring must not depend on display frame rate.
5. **Payments:** configure proposed non-consumable products, verify purchases and restore ownership through StoreKit. Test success, cancellation, pending purchase, refund/revocation, offline launch and restored purchases on both platforms using StoreKit testing and TestFlight where applicable.
6. **Distribution:** prepare separate iPadOS/macOS builds, screenshots, age rating, privacy disclosures and review information. Configure one App Store Connect app record with the relevant platforms if choosing universal purchase. Test real devices before App Review. Membership permits submission; it does not guarantee acceptance.

## 5. Proposed monetization and payment flow

Suggested launch: one airport free and a permanent full-game unlock. Additional airport packs can follow if players want more content. Avoid interrupting active shifts with ads or selling emergency rescue purchases. Prices and demand have not been tested; no revenue forecast was established.

For App Store versions, the recommended flow is player → Apple purchase system → developer proceeds paid to the registered bank account. Stripe is not involved in those Apple transactions. Set up the Paid Apps Agreement, required tax forms and banking details in App Store Connect. The user's UK bank details remain subject to Apple's account/banking verification; no payment account has been configured here.

Under Apple's standard terms checked on 18 November 2026, the commission on paid apps and in-app purchases is generally 30%, or 15% after eligibility and enrolment in the App Store Small Business Program. The reduced rate is not automatic with Developer Program membership. Its USD1million proceeds test includes associated accounts and other conditions. Proceeds also account for applicable taxes and adjustments; do not treat a retail price minus commission as guaranteed bank receipts. Payouts are monthly and, when Apple's requirements are met, within 45 days after the relevant Apple fiscal month ends.

Stripe is an option for a separate Mac edition sold directly through a website. External checkout links inside App Store games depend on customer storefront and applicable terms; owning Stripe or a UK bank account does not create a universal exemption. Recheck the rules before implementing external payments. Universal purchase can let customers obtain related iPad/Mac App Store versions and compatible purchases together; configure this deliberately before launching separate app records.

## 6. Official references

- SpriteKit: https://developer.apple.com/documentation/spritekit/
- SwiftUI: https://developer.apple.com/documentation/swiftui/
- StoreKit: https://developer.apple.com/documentation/storekit/
- Universal purchase: https://developer.apple.com/help/glossary/universal-purchase
- Payment rules: https://developer.apple.com/app-store/review/guidelines/#payments
- Standard commission: https://developer.apple.com/programs/whats-included
- Small Business Program: https://developer.apple.com/app-store/small-business-program/
- Payments and banking requirements: https://developer.apple.com/help/app-store-connect/getting-paid/overview-of-receiving-payments

## 7. Next action

When development is requested, confirm the first prototype's control style and create the shared Swift simulation plus a minimal playable radar scene. Work in this folder, separate from PeakSpeak. Reuse the user's workstyle at `/Users/pablo/.codex/WORKSTYLE.md`; conserve Codex usage, communicate in numbered points and distinguish proposed, implemented and verified work.
