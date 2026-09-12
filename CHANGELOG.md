# Changelog

## 0.3.8
- Popup now opens anchored under the bar icon you click, instead of centered on screen.

## 0.3.7
- Locked down process spawning (fixed identities, closed environment, fail-closed directory checks).

## 0.3.6
- Hardened the state file path against symlink attacks on both read and write.

## 0.3.5
- Doubled popup scroll speed and paced GeoIP lookups to avoid rate limits.

## 0.3.4
- Second security pass: fixed private-IP detection gaps, a WHOIS race condition, and safer theme file I/O.
- Connections list polish: bigger flag icons, stable ordering, faster scrolling, GeoIP backoff.
- Fixed the Traffic graph snapping and a rendering gap at the left edge while scrolling.

## 0.3.3
- Fixed Traffic graph peaks reshaping/wobbling while scrolling.

## 0.3.2
- Added a toggle for new-app notifications (off by default) and a default graph time window setting.
- Fixed the Traffic graph showing stale data after being closed for a while.

## 0.3.1
- Security hardening: GeoIP lookups now use HTTPS, fixed a WHOIS SSRF issue, bounded process usage.
- Dropped the whois binary dependency.
- Added the marketplace preview/hero banner.

## 0.3.0
- Initial release: live traffic gauges, history graph, connection list with country lookups, and LAN device discovery.
