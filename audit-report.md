# Pre-release audit — 2026-05-27

## Scope and limitations (read first)

This audit was performed by an agent operating with read-only file access to
`C:/projects/sis-aws/` and **no network, SSH, database, or process-execution
permissions**. Bash/PowerShell were sandboxed so that `curl`, `ssh`, `psql`,
`node <script>`, `git log`, and any HTTP request to `https://sistem.ehirshman.com`
were refused. As a result, the following steps from the original test program
**could not be executed**:

- Step 1 — runtime smoke (~100 endpoints): NOT RUN.
- Step 2 — CRUD smoke on 60+ entity types: NOT RUN.
- Step 3 — cross-entity flows (Lead→Contact, Quote→Project, public sign,
  Income sync): NOT RUN end-to-end.
- Step 4 — role-matrix tests with short-lived test users: NOT RUN.
- Step 6 — log tailing, cron heartbeat, disk usage, backup freshness: NOT
  RUN.
- Step 7a — `generateAccountStatement` PDF generation for Hebrew contacts:
  NOT RUN.
- Step 7b — Base44 file-migration URL fetches against S3: NOT RUN.
- Step 7c — real `sendEmail` to Brevo: NOT RUN.
- Step 7d — live `notificationCenterEvaluate` with `{force:true}`: NOT RUN.

What WAS done is a **deep static code audit** of the registry, the function
handlers, the auth/tenant middleware, the cron jobs, the public quote flow,
the multi-tenant RLS plumbing, and every frontend page that hard-codes a
role check. The findings below are all reproducible by reading the cited
file paths and line numbers; none are speculative.

The runtime audit still needs to happen before the first paying customer
goes live. The system has shipped a `super_admin` bypass that propagates
through `secureEntityAccess`, `PermissionGuard`, and `InternalAuthGuard`, but
several handlers and cron jobs predate that pattern and need fixes.

## Summary
- 110 backend functions in `C:/projects/sis-aws/backend/src/functions/`, 99
  registered endpoints (per `backend/src/functions/index.js`), 110 frontend
  pages.
- Static review of every authenticated handler, the tenant resolver, all 6
  cron jobs, the secureEntityAccess matrix, and 28 page-level role checks.
- **5 Critical** (multi-tenant data leaks or auth bypass — block public
  launch), **8 Important** (real user-visible bugs / privacy issues), **6
  Cosmetic**.

## Critical bugs (must fix before public launch)

### C1. `internalAuth` action `biometric_login` mints a JWT with no proof of identity
**File:** `C:/projects/sis-aws/backend/src/functions/internalAuth.js` lines 403–413
**Repro:** `POST /api/functions/internalAuth` body `{ "action": "biometric_login", "email": "victim@tenant.com" }`. The handler runs `findByEmail`, checks `is_active` and lock, then signs a 7-day session JWT and records it — **without verifying any WebAuthn credential, password, or one-time code**.
**Expected:** The handler should verify an assertion (e.g. via `@simplewebauthn/server`, same as `biometricAuth` does for Contacts) before issuing a session.
**Actual:** Any unauthenticated caller who knows an admin's email gets a valid 7-day admin JWT. The action is in `BYPASS_ACTIONS` (line 103), so it runs with `bypass_rls=on` and finds users across every tenant.
**Impact:** Full account takeover of any admin in any tenant. This is the single most dangerous issue in the codebase.
**Fix sketch:** Either delete the action entirely (no frontend code references `biometric_login`; grepped 1 file = only its own source) or wire it to a stored WebAuthn credential per `internal_auth` row.

### C2. Public quote links sign with a tenant-agnostic token and resolve in the wrong tenant
**Files:**
- `C:/projects/sis-aws/backend/src/lib/quoteToken.js` lines 25–50 — token payload is `quoteId:expiry:hmac`, no `tenant_id`.
- `C:/projects/sis-aws/backend/src/functions/getPublicQuoteLink.js` line 21 — builds link from `config.baseUrl` (platform host).
- `C:/projects/sis-aws/backend/src/functions/sendQuoteEmail.js` line 22 — same.
- `C:/projects/sis-aws/backend/src/functions/publicQuoteView.js` line 81 — `getEntity('PriceQuote', quoteId)` runs under whichever tenant the request's Host resolved to.

**Repro:** A tenant other than `hirshman` (the legacy fallback) creates a quote, calls `getPublicQuoteLink`, and emails the link. The URL points at `https://sistem.ehirshman.com/api/functions/publicQuoteView?token=...`. Customer opens link → `attachTenant` resolves Host to the legacy `hirshman` tenant → `getEntity('PriceQuote', quoteId)` runs RLS-scoped to hirshman → quote not found → 404.
**Expected:** Public quote URLs work for every tenant.
**Actual:** Public quote URLs only work for the hirshman tenant. The first paying tenant other than Hirshman will not be able to send a single quote-for-signing.
**Fix sketch:** Include `tenant_id` in the signed token, route `publicQuoteView`/`publicQuoteSign`/`publicQuoteUploadPO` through `runWithTenant({ tenantId, bypassRls: false })`, and have `getPublicQuoteLink`/`sendQuoteEmail` either (a) use the tenant's `custom_domain`/`primary_domain` for the URL, or (b) accept that the platform URL is canonical and decode the tenant from the token.

### C3. Cron jobs aggregate across every tenant and email a hardcoded phone number
**File:** `C:/projects/sis-aws/backend/src/cron.js`
All five cron jobs run under `runWithTenant({ bypassRls: true })` (line 152) with no `tenant_id` in the GUC, so every `entities` / `internal_auth` query spans the whole platform.
1. `checkExpiredQuotes` (lines 29–43): runs `UPDATE entities … type='PriceQuote'` globally — fine for the row update itself, but it doesn't iterate per tenant.
2. `sendQuoteAutoReminders` (lines 45–80): reminder link at line 68 uses `config.baseUrl`, so customers of every tenant get a hirshman-platform URL.
3. `dailySmartBrief` (lines 82–102) and `sendDailyTasksReport` (lines 104–118): COUNTs span every tenant, fall back to hardcoded `+972525355890` (the platform owner's phone) on line 100/113. Tenants A, B, C get no daily brief; the platform owner gets a single aggregate one that **mixes private data from every tenant**.
4. `sendMonthlyReport` (lines 120–147): the killer. `SUM(total_amount)` over `Income` and `Expense` across every tenant, then sends the result to `SELECT email FROM internal_auth WHERE role='admin'` — also unscoped. So tenant A's admin receives an email like "הכנסות: ₪Z, הוצאות: ₪Y" where Z and Y are tenant A's plus tenant B's plus tenant C's finances. **Direct disclosure of competitors' revenue.**

**Expected:** Cron should iterate the `tenants` table, call `runWithTenant({ tenantId: t.id })` for each, and aggregate per-tenant.
**Actual:** Single global aggregate, sent to a hardcoded phone or all admins.
**Mitigation:** Until fixed, `CRON_ENABLED=1` must NOT be left on once a second paying tenant is provisioned. Confirm via env on the AWS host (Step 6 not executable from this environment).

### C4. `createLeadFromForm` is public, hardcoded to the platform owner's phone, and emails admins of every tenant
**File:** `C:/projects/sis-aws/backend/src/functions/createLeadFromForm.js` lines 25–43
- Line 26: `to: '+972525355890'` — hardcoded WhatsApp recipient.
- Line 30: `SELECT email FROM internal_auth WHERE role='admin'` — RLS-scoped to whichever tenant `attachTenant` resolved by Host. Acceptable for hirshman's contact form, broken for any subdomain or custom domain (admins from the wrong tenant get the email if Host resolves to legacy).

If a customer puts a contact form at `<tenantA>.sistem.ehirshman.com`, Host resolves to tenant A → admins from tenant A get the WhatsApp + email — wait, the WhatsApp goes to the hardcoded number, NOT tenant A's admin. So every lead from every tenant's public form pings hirshman's phone (and emails the right admins by accident only). Need a per-tenant admin phone source.
**Expected:** Use `loadTenantSettings(req.tenant.id).admin_phone` (already exists in `cron.js` line 24).
**Actual:** Hardcoded `+972525355890`.

### C5. Multi-tenant Activity/Note/Reminder/EmailTemplate/etc. reads return 403 for sales/accounting/field_worker
**File:** `C:/projects/sis-aws/backend/src/functions/secureEntityAccess.js` lines 9–58
`ENTITY_CONFIG` covers 42 entity types. The fallback for unlisted entities (line 102) is `['admin', 'system_manager']`. The frontend calls `secureData.X` for the following entities that are NOT in `ENTITY_CONFIG`:

| Entity | Used in pages |
|---|---|
| Activity | `LeadDetails.jsx`, `Leads.jsx`, `ContactDetails.jsx`, `SalesDashboard.jsx`, `Activities.jsx` |
| Note | `LeadDetails.jsx`, `ContactDetails.jsx` |
| Reminder | `LeadDetails.jsx`, `Leads.jsx`, `RemindersPanel.jsx`, `Home.jsx`, `Dashboard.jsx` |
| ReferralSource | `ReferralSources.jsx`, `SalesDashboard.jsx`, `Leads.jsx`, `LeadForm.jsx`, `ContactForm.jsx` |
| LeadAutomationRule | `LeadAutomation.jsx`, `LeadAutomationRuleForm.jsx` |
| AutomationRule | `AutomationRules.jsx`, `AutomationRuleForm.jsx` |
| EmailTemplate | `EmailTemplates.jsx`, `SendEmailDialog.jsx`, `SendQuoteEmailDialog.jsx` |
| EmailLog | (used by sendCustomEmail backend, not directly by UI) |
| QuoteDocument | `QuoteDetails.jsx`, `DocumentsManager.jsx`, `SplitQuoteDialog.jsx` |
| QuoteHistory | `QuoteDetails.jsx`, `QuoteHistoryPanel.jsx` |
| DocumentTemplate | `DocumentTemplates.jsx`, `DocumentTemplateForm.jsx` |

**Repro (static):** log in as a `sales`-role user, open `LeadDetails`. The page calls `secureData.Activity.filter({lead_id})` and `secureData.Reminder.filter({lead_id})`. Both hit `secureEntityAccess` → `checkPermission(sales, 'Activity', 'read')` → entity not in `ENTITY_CONFIG` → fallback `['admin','system_manager']` → 403.
**Expected:** Sales should be able to view and create lead Activities/Notes/Reminders.
**Actual:** Sales role cannot use the lead-management UI at all. Same for accounting (no Activity access), field_worker (no Reminder access), and for the Lead→Contact conversion flow on `Leads.jsx` line 175–195 which calls `secureData.Activity.list()` and `secureData.Reminder.list()` and silently swallows errors.
**Fix sketch:** Add explicit entries to `ENTITY_CONFIG` for the 11 missing entity types with appropriate `read`/`write` role sets.

## Important bugs (should fix soon)

### I1. `verifyClientCode` allows brute force of the 6-digit code
**File:** `C:/projects/sis-aws/backend/src/functions/verifyClientCode.js`
No failed-attempt counter, no rate-limit per-session, no incremental code rotation. Only the platform-wide `writeLimiter` (600/min) protects; an attacker with a known `sessionId` can submit 100 guesses well within the 10-minute window. **Fix:** add a per-session `failed_attempts` counter and invalidate after 5 failures.

### I2. `signupTenant` and `inviteUser` leak the verify/accept URL on email-send failure
**Files:** `signupTenant.js` line 164, `inviteUser.js` line 167
The handler returns `verification_url`/`invite_url` in the JSON body when `sendEmail` returns `{skipped: true}` or throws. Intended as a dev convenience, but it ships in production. If Brevo/SendGrid is misconfigured for a tenant, anyone signing up or being "invited" can immediately verify ownership of an email they don't control. **Fix:** gate this on `config.env !== 'production'`.

### I3. `updateTask` rejects super_admin who is not the task creator or assignee
**File:** `C:/projects/sis-aws/backend/src/functions/updateTask.js` line 24
`const isAdmin = user.role === 'admin' || user.role === 'system_manager';` does not include `super_admin`. Line 32: `if (!isAdmin && !isOwner && !isFieldWorker) return 403`. So a platform owner doing customer support can't update a task they didn't create. **Fix:** include `super_admin` in the isAdmin check (same fix applied elsewhere).

### I4. `NotificationBell` excludes super_admin from approving recurring transactions
**File:** `C:/projects/sis-aws/source/src/components/shared/NotificationBell.jsx` lines 158, 224, 238, 259, 281
Five `allowedRoles = ['admin', 'system_manager', 'accounting']` lists, none of them include `super_admin`. When the platform owner is viewing the system they will see the bell but every action (`handleApprove`, `handleCancelOnce`, `handleCancelPermanent`, `handleFormSubmit`, the loader at line 159) shows "אין לך הרשאות" or silently returns. **Fix:** add `super_admin` to all five arrays.

### I5. `EmployeePortal` and `Layout` `isAdmin` don't include super_admin
**Files:**
- `source/src/pages/EmployeePortal.jsx` line 538: `isAdmin = … (role === 'admin' || role === 'system_manager')` — super_admin won't see the employee-switcher dropdown (line 587) and is shown the single-employee view.
- `source/src/Layout.jsx` line 654: same — note that lines 661–666 then patch the gap by adding `|| role !== 'super_admin'` to each menu predicate, which suggests the author noticed the pattern but missed the consumers downstream.

**Fix:** define `isAdmin = role === 'super_admin' || role === 'admin' || role === 'system_manager'` once at the right place.

### I6. `EmployeeHome` shows "no employee profile" to super_admin
**File:** `source/src/pages/EmployeeHome.jsx` line 48
`if (user?.role === 'admin')` shows the admin greeting; super_admin falls through to line 63 ("שגיאה — לא נמצא פרופיל עובד"). Cosmetic, but it's the kind of bug a paying customer will screenshot.

### I7. `customerBotAuth` enumerates contacts and is brute-forceable
**File:** `C:/projects/sis-aws/backend/src/functions/customerBotAuth.js`
- A `phone`/`email` that exists returns `{ success, session_id, contact_id, masked }`; non-existent returns `{ error: 'contact_not_found' }`. Same code path as I1, but at the *lookup* step: anyone can probe whether a given phone or email is a customer of a tenant. Combine with the `sistem.ehirshman.com` Host = legacy tenant default and you can scan the platform owner's customer list. **Fix:** return a uniform "we sent a code if a match was found" reply.

### I8. `auditLogSearch` returns cross-tenant rows to super_admin's `list` action
**File:** `C:/projects/sis-aws/backend/src/functions/auditLogSearch.js` lines 32–62
For super_admin, `superAdminBypass` middleware (server.js line 115) sets `bypassTenantRLS = true`, so `list` (not `listAll`) also returns rows from every tenant. Surprising UX — the super_admin's "list" filter should still scope to the tenant they're "in" (via Host) unless they explicitly pick `listAll`. **Fix:** when `action='list'` and the user is super_admin, run inside `runWithTenant({ tenantId: req.tenant.id, bypassRls: false })`.

## Cosmetic / nice-to-have

- **CO1** — `PageNotFound.jsx` line 41: "Admin Note" debug block only shown to `role === 'admin'`, not super_admin. Harmless.
- **CO2** — `cron.js` line 26: `'+972525355890'` is the platform owner's mobile, also referenced in `createLeadFromForm.js`. Magic-number; move to env or `tenant.settings.admin_phone`.
- **CO3** — `getFieldWorkerData.js` lines 15, 21, 29: loads ALL projects, tasks, contacts (`limit: 100000`) and filters in JS. Fine at hirshman scale; will be a memory blip when a tenant grows past ~10k projects. Add server-side filter on `field_workers` and `assigned_to`.
- **CO4** — `apiTokensManage` line 39: allows `super_admin`/`admin` only, no `system_manager`. Consistent with `apiTokens` being a Pro+ feature, but other admin-y pages let `system_manager` through; pick a single rule.
- **CO5** — `attachUser`/`validateApiToken` line 35: `role: rec.role || 'admin'` — an API token created without a role defaults to admin. Make the default `'user'` (least privilege) and require explicit role on creation.
- **CO6** — `Layout.jsx` line 654 vs 663: `isAdmin` excludes super_admin but each consumer downstream re-checks. Refactor once.

## Verified working (static review only)

- `secureEntityAccess.js` lines 100–103 correctly bypasses checks for `super_admin` on the 42 entities it knows about.
- `PermissionGuard.jsx` line 42 explicitly allows `super_admin || admin || system_manager`.
- `InternalAuthGuard.jsx` line 65 explicitly grants every page to `super_admin`.
- `apiTokensManage` stores hashes (SHA-256), never plaintext, and reveals the plaintext only on creation (line 61).
- `signupTenant` enforces password ≥ 8 chars (line 52), slug uniqueness with `ON CONFLICT` semantics, and 14-day trial.
- `billingWebhook` verifies HMAC via `provider.verifyWebhook` (line 82) before mutating tenant state.
- `internalAuth` login (lines 115–158) has account-lockout after 5 failed attempts for 15 minutes, hashes upgrades on login, and writes audit log entries.
- Multi-tenant RLS policies on `entities`, `internal_auth`, `audit_log`, `files`, `counters` are correctly created in `migrations/002_multitenancy.sql` lines 109–138 with both `tenant_isolation` and `super_admin_bypass` policies.
- The function dispatcher (`functions/index.js` lines 371–408) wires `requireAuth`, plan feature gating, billing-suspend gating, per-function role allowlists, and API-token scope checks before reaching any handler.

## Suggested next steps

1. **Stop calling `internalAuth` with `biometric_login` reachable.** Either delete the action or wire it to WebAuthn. Until then, an explicit fence: add the action to the `action === 'biometric_login'` branch right after line 403, e.g. `return res.status(503).json({ error: 'disabled' })`. (C1)
2. **Embed tenant_id in `quoteToken` and route public quote endpoints through `runWithTenant`.** Existing tokens in the wild belong to hirshman only and can be migrated trivially. (C2)
3. **Rewrite cron jobs to iterate tenants.** Pattern: `SELECT id FROM tenants WHERE billing_status IN ('active','trialing')` then for each call `runWithTenant({ tenantId: t.id }, fn)`. (C3)
4. **Replace hardcoded `+972525355890` with `loadTenantSettings(req.tenant.id).admin_phone`** in `createLeadFromForm.js` and `cron.js`. (C4)
5. **Add the 11 missing entities to `ENTITY_CONFIG`** with sales/accounting/field_worker as appropriate. Then run a full lead/quote/contact UI walkthrough as each non-admin role. (C5)
6. **Run Steps 1–4 and 6–7 from the original test program** in a shell with network access, ideally before fixing C1–C5 so you have a pre/post comparison. Save the curl scripts to `/tmp/audit-*.sh` so they're reusable for regression testing.

## Final recommendation

**Thumbs DOWN** for showing this to the first paying customer until C1 (auth bypass), C2 (public quote links), C3 (cron data leak), C4 (hardcoded phone in public form), and C5 (sales/accounting role can't use the CRM) are fixed. Of these, C1 is exploitable from anywhere on the internet and should be patched today; C2 and C5 will surface within hours of the first non-hirshman tenant trying to use the product as documented.

The platform plumbing (RLS, JWT, billing webhook signing, password hashing, audit logs, role-aware guard component, API-token hashing) is sound. The bugs are in the few handlers that pre-date the multi-tenant refactor and in the role-check sites that haven't yet absorbed the `super_admin` exception. None of the issues require architectural changes — they're all localized fixes.

A runtime smoke pass (Steps 1, 2, 4, 6, 7) is still required and has NOT been performed in this audit.
