# LifeTrack Today UI — Design QA

- Source visual truth: `/Users/aotelei/coding/sport_app/DesignQA/design-reference-today.png`
- Implementation screenshot: `/Users/aotelei/coding/sport_app/DesignQA/implementation-today-final.png`
- Side-by-side evidence: `/Users/aotelei/coding/sport_app/DesignQA/design-qa-comparison.png`
- Viewport: iPhone 17 Pro simulator, 402 × 874 pt
- Source pixels: 853 × 1844, normalized with aspect-fill to 1206 × 2622
- Implementation pixels: 1206 × 2622 at 3× density
- State: 2026-08-18, idle recording state, no saved route, simulated Shanghai location, dark appearance

## Findings

No actionable P0, P1, or P2 differences remain.

- Fonts and typography: The implementation uses condensed/monospaced system typography instead of the mock's generated display face. Weight, scale, hierarchy, tabular numerals, Chinese legibility, and single-line wrapping match the intent. The system fallback is intentional to preserve Dynamic Type and Chinese glyph coverage.
- Spacing and layout rhythm: Header, date block, primary action, map, telemetry, and persistent navigation retain the reference order and proportions. Main regions use 12–14 pt continuous corners, lighter separators, and no nested floating-card treatment.
- Colors and visual tokens: Graphite background, acid-lime action/selection, safety-orange GPS state, muted gray text, and low-contrast borders match the selected direction. No gradients or translucent materials remain in the redesigned shell.
- Image quality and asset fidelity: The map is a live MapKit surface rather than a raster placeholder. It therefore shows the actual empty-route state and simulated location instead of the mock's illustrative completed route; this is an expected product-state difference and avoids presenting fabricated user data.
- Copy and content: `GPS 待命`, `开始记录`, date, recording state, `0.00 公里`, `00:00`, `自动识别`, and all five navigation labels match the intended product content.
- Accessibility and affordance: Primary and map controls meet or exceed 44 pt touch targets, retain accessibility labels/hints, and metrics adapt through `ViewThatFits` for larger text sizes.

## Focused Evidence

A separate crop was not needed because the 2412 × 2622 side-by-side comparison keeps the header, primary CTA, map controls, telemetry typography, borders, radii, and navigation icons readable at native screenshot density.

## Comparison History

1. Initial capture found a P1 mismatch: the system tab bar introduced a translucent rounded material that contradicted the approved non-Apple visual direction. Fixed by hiding the system tab bar and adding a solid, full-width custom navigation bar.
2. Initial capture found a P2 map-control issue: a divider expanded the vertical toolbar across too much of the map. Fixed by constraining the control group to 46 pt.
3. Initial capture found P2 telemetry drift: empty values rendered as `0 米` and `0 秒`. Fixed with stable instrument readouts `0.00 公里` and `00:00`.
4. The empty map could remain at a national zoom when the first location arrived after view creation. Fixed by centering from the MapKit user-location delegate when no initial region has been established. The final screenshot shows a practical local Shanghai map.

## Follow-up Polish

- P3: A bundled licensed condensed Latin display font could make the `LIFETRACK` wordmark even closer to the generated mock, but the current system-condensed treatment is production-safe and visually consistent.
- P3: A populated-track screenshot can be added later to compare route-line treatment against the mock's lime dashed route.

## Implementation Checklist

- [x] Preserve the real recording start/stop/save state machine.
- [x] Preserve map positioning, full-route, and place-marking actions.
- [x] Preserve activity selection and detail navigation.
- [x] Replace glass/material navigation with a solid instrument shell.
- [x] Verify a signed-off empty state on the iPhone 17 Pro simulator.
- [x] Pass an unsigned generic iOS Simulator build.

final result: passed
