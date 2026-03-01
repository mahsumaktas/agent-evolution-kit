# Reflection: 2026-02-28 - researcher-agent - NVD API vulnerability scan

## What happened?

Attempted to scan NVD API for recent CVEs affecting Node.js and macOS. Expected to retrieve and filter ~50 CVEs from the last 7 days.

## What went wrong?

Received HTTP 429 (rate limit exceeded) after the first API call. The scan was initiated at 03:15 UTC, which falls within NVD's peak rate-limiting window.

## Why did it go wrong?

NVD API applies stricter rate limits during nighttime hours (US timezone). The cron schedule triggered the scan at a time when rate limits are most aggressive. Previous successful scans ran during daytime hours but this wasn't codified as a rule.

## What should I do differently?

Schedule API-heavy scans during daytime hours (09:00-17:00 UTC). If rate-limited, wait 30 minutes and retry rather than failing immediately. Consider caching results to reduce API call frequency.

## Tactical rule candidate

IF NVD API returns 429, THEN wait 30 minutes and retry. IF retry also fails, THEN switch to daytime schedule and report partial results.

---

# MARS Extraction

## Principle (Normative)

External API calls should be scheduled during the API provider's off-peak hours. Always implement retry with backoff before declaring failure.

## Procedure (Descriptive)

1. Check API rate limit status before starting batch queries
2. If rate-limited, wait 30 minutes (exponential backoff)
3. If still limited, defer to next available daytime window
4. Log the failure with timestamp for pattern detection
5. Report partial results with explicit data gap notification
