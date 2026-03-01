# Evolution Log

Record of all changes made through the weekly self-evolution cycle.

---

## 2026-W08 (Feb 24 - Mar 2)

- **Change:** Added tactical rule to researcher-agent: "IF NVD API returns 429, wait 30min and retry during daytime hours"
- **Reason:** 3 consecutive tasks hit NVD rate limits during nighttime scans
- **Expected impact:** Rate-limit failures should drop to 0%
- **Rollback:** Remove the rule line from researcher-agent prompt
- **Blast radius:** Only researcher-agent API scanning is affected
- **Status:** SUCCESSFUL
- **Verification:** W09 showed 0 rate limit errors. Rule retained.

## 2026-W09 (Mar 3-9)

- **Change:** Switched finance-agent model from sonnet to opus
- **Reason:** 3 hallucinations in financial analysis reports within one week
- **Expected impact:** Hallucination rate should decrease by ~50%
- **Rollback:** Switch model back to sonnet
- **Blast radius:** Finance-agent tasks will cost more (~2x) but accuracy should improve
- **Status:** APPLIED
- **Verification:** _(W10 VERIFY pending)_

## 2026-W10 (Mar 10-16)

- **Change:** Added strategic rule to social-media-agent: "Thread format with question hook generates ~40% more engagement than single posts"
- **Reason:** 4 weeks of trajectory data confirm consistent engagement improvement with thread format
- **Expected impact:** Average engagement per post should increase
- **Rollback:** Remove the rule line from social-media-agent prompt
- **Blast radius:** Only social media content format is affected
- **Status:** DRAFT
- **Verification:** _(awaiting operator approval)_
