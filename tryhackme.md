# Chimp Home Server --- Security Findings & Remediation

**Assessment date:** 8 November 2026\
**Repository:** `nazufernandes/chimp-home-server`\
**Assessment type:** Source-code review and limited, non-destructive
live HTTP validation\
**Status:** Preliminary assessment; remediation and retesting
outstanding.

> **Evidence note:** This report separates source-confirmed weaknesses
> from issues observed on the live instance. A vulnerable code path is
> not proof that it was successfully exploited in production. No command
> execution, destructive requests, uploads, deletion, brute force, or
> load/DoS testing was performed against the public instance.

## 1. Executive summary

The review identified a critical command-execution design flaw in
ChimpCron and multiple high-risk unauthenticated API surfaces across
ChimpDrive, ChimpDrop and ChimpPix. Public monitoring endpoints were
reachable and disclosed infrastructure/process metadata. A public
ChimpDrop API response contained one clipboard entry with content; the
content was deliberately not inspected or reproduced.

**Recommendation:** Do not expose the current deployment to unrestricted
public access until Priority 0 containment and the high-priority
remediations below are completed.

## 2. Findings summary

  -------------------------------------------------------------------------------------------
  ID                Severity          Finding               Evidence status
  ----------------- ----------------- --------------------- ---------------------------------
  SEC-01            Critical          ChimpCron             Source-confirmed; live exploit
                                      caller-controlled     not attempted; Cron returned HTTP
                                      shell command         502
                                      execution             

  SEC-02            High              ChimpDrive file APIs  Source-confirmed; live listing
                                      lack visible          reachable, empty
                                      authentication checks 

  SEC-03            High              ChimpDrop             Source-confirmed; live response
                                      clipboard/file APIs   exposed one entry containing
                                      lack visible          content
                                      authentication checks 

  SEC-04            High              ChimpPix photo APIs   Source-confirmed; live listing
                                      lack visible          reachable, empty
                                      authentication checks 

  SEC-05            High              Unsafe HTML rendering Source patterns confirmed;
                                      / stored XSS risk     browser PoC not executed

  SEC-06            High              Default administrator Source/configuration-confirmed;
                                      password fallback     live login not tested

  SEC-07            High              Public monitoring     Confirmed on live instance
                                      information           
                                      disclosure            

  SEC-08            Medium            Wildcard CORS         Source-confirmed; wildcard header
                                                            observed on live monitoring
                                                            responses

  SEC-09            Medium            Upload/storage        Source/configuration concern;
                                      resource exhaustion   exhaustion not tested
                                      risk                  

  SEC-10            Medium            Cron timeout/output   Source-confirmed; live behavior
                                      resource controls     not tested

  SEC-11            Medium            Photo-sync            Source-level concern; live
                                      concurrency/control   behavior not tested
                                      risk                  

  SEC-12            Medium            Dependency and        Configuration concern; deployed
                                      installer             versions/CVEs unknown
                                      supply-chain controls 
  -------------------------------------------------------------------------------------------

Severity reflects potential impact and exposure, not successful
exploitation of every issue.

## 3. Detailed findings and solutions

### SEC-01 --- ChimpCron caller-controlled shell command execution

**Severity:** Critical\
**Evidence:** `cron/app.py` accepts caller-supplied job commands and
executes them through a shell using a pattern equivalent to
`subprocess.run(["bash", "-c", command], ...)`. Job-management routes
cover creation, update, deletion, toggle and manual execution. No
authentication/authorization check was visible in the reviewed route
implementations. Live `/cron/api/jobs` and `/cron/api/history` returned
HTTP 502, so live exploitability is unverified.

**Impact:** If reachable by an unauthenticated remote caller, commands
may execute with the Cron service's OS privileges. Depending on those
privileges, this could expose or modify data, access credentials,
disrupt services or compromise the host.

**Remediation:** 1. Immediately disable or firewall public access to
ChimpCron. 2. Require authentication and administrator authorization for
every job operation. 3. Do not accept arbitrary shell commands from
clients. Replace them with an allowlist of predefined job types and
validated parameters. 4. If execution is necessary, invoke a fixed
executable with an argument array. Do not use `bash -c`, `shell=True`,
or interpolated command strings. 5. Run Cron as a dedicated unprivileged
OS account with minimal filesystem/network permissions. 6. Enforce
server-side execution time, output, concurrency and queue limits. 7.
Audit job creation, modification and execution without logging secrets.

**Retest:** Anonymous operations are rejected; arbitrary commands are
impossible; only approved jobs run under a restricted account.

### SEC-02 --- ChimpDrive unauthenticated file-management operations

**Severity:** High\
**Evidence:** `files/app.py` exposes listing, raw/content retrieval,
ZIP, save, upload, folder creation, delete and rename operations. No
authentication check was visible in the reviewed route implementations.
Live `/files/api/files` returned HTTP 200 with an empty listing. This
proves route reachability, not disclosure of private file contents. The
source includes path-containment checks, which should be retained.

**Impact:** A remote visitor may be able to enumerate/read stored files
or upload, overwrite, rename and delete files if these routes are
publicly reachable.

**Remediation:** 1. Require authentication and authorization on every
route, including raw downloads and ZIP generation. 2. Check
authorization for each individual resource, not just the UI. 3. Retain
canonical path resolution and verify every resolved path remains inside
the configured storage root. 4. Generate server-side storage names;
never trust client paths. 5. Store uploads outside the web root and
prevent execution/rendering. 6. Validate actual file content, not just
extension or client MIME type. 7. Enforce file-size limits, quotas, rate
limits and concurrency limits. 8. Prevent overwrite/delete/rename unless
explicitly authorized; audit changes.

**Retest:** Anonymous requests fail; authorized users access only
permitted files; traversal cannot escape storage; uploads cannot
overwrite arbitrary paths.

### SEC-03 --- ChimpDrop unauthenticated clipboard and file operations

**Severity:** High\
**Evidence:** `drop/app.py` exposes clip listing/retrieval, file
retrieval, clip creation, upload, pin, delete and clear operations. No
authentication check was visible in the reviewed route implementations.
Live `/drop/api/clips` returned HTTP 200 with one clipboard entry
containing content. The content was not inspected. `secure_filename()`
is used for upload names, but that is not access control.

**Impact:** Clipboard data can contain sensitive copied text, URLs,
codes or snippets. Public read access can disclose it; public
write/delete/clear operations can tamper with or destroy it.

**Remediation:** 1. Require authentication and authorization for all
clipboard and file routes. 2. Treat clipboard contents as sensitive by
default. 3. Use opaque unpredictable identifiers and authorize every
resource lookup. 4. Restrict bulk clear operations to administrators. 5.
Validate upload content and size; store outside the web root. 6. Add
rate limits and audit logging without recording clipboard contents.

**Retest:** Anonymous users cannot list/read clips; unauthorized users
cannot modify, pin, delete or clear entries; file downloads require
authorization.

### SEC-04 --- ChimpPix unauthenticated photo operations

**Severity:** High\
**Evidence:** `photos/app.py` exposes photo listing, thumbnail/photo
retrieval, metadata, upload, delete and synchronization routes. No
authentication check was visible in the reviewed route implementations.
Live `/photos/api/photos` returned HTTP 200 with zero photos and
folders. The sync path invokes a backup script via `subprocess`; it was
not triggered.

**Impact:** If reachable, an unauthenticated visitor may enumerate or
retrieve photos/metadata, upload or delete photos, or trigger
resource-intensive synchronization.

**Remediation:** 1. Require authentication and authorization for all
photo, thumbnail, metadata, upload, delete and sync routes. 2. Retain
canonical path checks and enforce containment for every requested path.
3. Generate server-side filenames and reject path components. 4.
Validate image content, dimensions and pixel count; enforce size/time
limits. 5. Restrict sync to administrators and use a server-side lock to
prevent concurrent runs. 6. Run backup scripts from fixed trusted paths
under least privilege. 7. Consider removing sensitive EXIF metadata from
publicly served copies.

**Retest:** Anonymous operations fail; traversal cannot escape photo
storage; unauthorized delete/sync is denied; concurrent sync is
controlled.

### SEC-05 --- Unsafe HTML rendering / stored XSS risk

**Severity:** High\
**Evidence:** Reviewed UI code interpolates application data into HTML
strings and renders it as HTML. Examples include
`photos/templates/index.html` (photo names/folders),
`files/templates/index.html` (filenames/paths and inline event handlers)
and `drop/templates/index.html` (clipboard metadata and identifiers).
User-controlled filenames or clipboard data may reach these rendering
paths. A browser proof of concept was not executed.

**Impact:** If attacker-controlled values reach an executable
HTML/JavaScript context, a malicious value may execute script in a
visitor's browser under the application's origin. The impact depends on
the complete data flow and session design.

**Remediation:** 1. Construct DOM nodes and assign untrusted values
through `textContent`. 2. Avoid `innerHTML`, `outerHTML` and HTML
template strings for untrusted data. 3. Remove inline event handlers;
attach event listeners programmatically. 4. Apply context-appropriate
output encoding where HTML is unavoidable. 5. Validate inputs, but do
not treat validation as a substitute for output encoding. 6. Add a
restrictive Content Security Policy; avoid `unsafe-inline` where
practical. 7. Use secure session/cookie settings where cookies are used.
8. Add regression tests proving harmless XSS marker strings render as
text.

**Retest:** User-controlled values render only as text; no script/event
execution occurs; CSP is appropriately restrictive.

### SEC-06 --- Default administrator password

**Severity:** High\
**Evidence:** `monitor/monitor.py` contains an `admin` fallback;
`.env.example` sets `CHIMP_ADMIN_PASSWORD=admin`; `install.sh` defaults
to `admin` when no value is entered. `manage.sh` also contains
example-configuration fallback behavior in the reviewed setup flow. Live
login was not tested and no brute force was attempted.

**Impact:** A deployment retaining the known default may allow access to
administrative controls, potentially including service, process or
tunnel management.

**Remediation:** 1. Remove all default/fallback passwords. 2. Refuse to
enable the admin interface until a strong secret is configured through a
secure first-run setup. 3. Store passwords using Argon2id, scrypt or
bcrypt, not plaintext. 4. Add login rate limiting and progressive
delay/lockout. 5. Protect sessions with secure cookie settings, CSRF
protection and session rotation. 6. Require re-authentication for
high-impact actions. 7. Exclude `.env` from source control, restrict its
filesystem permissions and rotate potentially exposed credentials.

**Retest:** Fresh installs cannot use a known default; incomplete setup
fails safely; login is rate-limited; secrets are not exposed in
repository or logs.

### SEC-07 --- Public monitoring API information disclosure

**Severity:** High\
**Evidence:** `monitor/monitor.py` exposes `/api/status`,
`/api/services`, `/api/admin/processes`, `/api/admin/tunnel` and
`/api/admin/ports`. Live public GET requests returned HTTP 200.
Responses disclosed internal hostname/private IP, public tunnel URL, SSH
host/port/username metadata, service inventory/ports/states, process
IDs, OS username, resource use and process command information. This
does **not** prove SSH authentication was bypassed or the server
accessed.

**Impact:** The information helps an attacker map the environment,
identify services and ports, and plan follow-on attacks.

**Remediation:** 1. Require authentication for monitoring and all
administrative diagnostics. 2. Separate a minimal public health endpoint
from private diagnostics. 3. Remove SSH details, process command lines,
hostnames, private addresses and tunnel details from public responses.
4. Restrict administration to a VPN/private network or trusted
management interface. 5. Apply role checks to
process/service/tunnel/port controls. 6. Avoid exposing command lines
that may contain arguments or secrets. 7. Keep `Cache-Control: no-store`
for sensitive responses, but do not treat it as access control.

**Retest:** Anonymous diagnostic requests return 401/403; public health
output is minimal; authorized administrators see only necessary data.

### SEC-08 --- Wildcard CORS

**Severity:** Medium\
**Evidence:** Reviewed Flask services set
`Access-Control-Allow-Origin: *`; wildcard CORS was observed on live
monitoring responses.

**Impact:** Other origins may be able to read responses through browser
JavaScript. CORS alone is not authentication and does not independently
bypass server authorization; it increases exposure when sensitive APIs
are already public.

**Remediation:** 1. Replace wildcard CORS with an explicit
trusted-origin allowlist. 2. Restrict methods and headers to those
required. 3. Do not combine credentialed requests with wildcard origins.
4. Do not reflect arbitrary `Origin` values. 5. Keep server-side
authentication and authorization regardless of CORS.

**Retest:** Untrusted origins cannot read protected responses; the
approved frontend continues to work.

### SEC-09 --- Upload and storage resource exhaustion

**Severity:** Medium\
**Evidence:** Reviewed Nginx configuration permits request bodies up to
approximately 500 MB. Upload routes exist in Drive, Drop and Pix.
Comprehensive per-user quotas/application-level resource controls were
not established by the reviewed code. No exhaustion test was performed.

**Impact:** Repeated or oversized uploads may consume disk, memory, CPU
or image-processing capacity.

**Remediation:** 1. Set conservative request-body limits at both proxy
and application layers. 2. Enforce per-file, per-user and total-storage
quotas. 3. Limit upload concurrency and request rates. 4. Stream files
rather than buffering large uploads in memory. 5. Validate file
signatures/content and reject unsupported formats. 6. Limit image
dimensions, processing time and decompressed pixel count. 7. Add storage
monitoring and retention/cleanup policies. 8. Return 413 or a clear
quota response when limits are exceeded.

**Retest:** Oversized uploads are rejected early; quotas and concurrency
limits work; normal uploads remain functional.

### SEC-10 --- Cron timeout and output resource controls

**Severity:** Medium\
**Evidence:** The reviewed Cron implementation accepts caller-influenced
job parameters and captures subprocess output before truncating stored
output. The timeout is not adequately bounded by a server-enforced
maximum in the reviewed path. This compounds SEC-01.

**Impact:** Approved jobs may still consume excessive CPU, memory,
worker capacity or disk if runtime/output is not bounded.

**Remediation:** 1. Enforce a server-side maximum execution duration. 2.
Bound stdout/stderr while the process runs, not only after collecting
all output. 3. Stream to a fixed-size buffer or bounded log file. 4.
Limit concurrent jobs and queue length. 5. Terminate process groups
reliably on timeout. 6. Apply OS-level CPU, memory and filesystem
restrictions where possible. 7. Bound history retention and rotate logs.

**Retest:** Excessive timeouts are rejected/clamped; output cannot grow
without bound; concurrency and history limits are enforced.

### SEC-11 --- Photo synchronization concurrency risk

**Severity:** Medium\
**Evidence:** `photos/app.py` tracks sync state in process memory and
invokes a backup script through `subprocess`. The design should be
verified to prevent overlapping synchronization operations. Live sync
was not triggered.

**Impact:** Concurrent requests may start duplicate jobs, consume
resources or conflict over backup data.

**Remediation:** 1. Use a server-side lock so only one sync runs at a
time. 2. Require administrator authorization. 3. Add cooldown/rate
limits and bounded execution time. 4. Use a fixed trusted script path
and fixed argument list. 5. Run sync under a restricted account. 6.
Ensure failure/timeout leaves recoverable state and does not expose
sensitive paths.

**Retest:** Concurrent requests do not launch multiple sync jobs;
unauthorized sync is rejected; state recovers after failure.

### SEC-12 --- Dependency and installer supply-chain controls

**Severity:** Medium\
**Evidence:** Dependency constraints include minimum versions (for
example Flask, Pillow and Werkzeug). The installer downloads an Ngrok
binary without a separately verified checksum/signature step in the
reviewed flow. Exact deployed versions are unknown; no specific CVE is
asserted.

**Impact:** Unpinned dependencies reduce build reproducibility;
unverified executable downloads increase supply-chain risk.

**Remediation:** 1. Pin direct and transitive dependencies with a lock
file and hashes. 2. Scan dependencies and update through a controlled
process. 3. Generate an SBOM for releases. 4. Verify downloaded binaries
using vendor-published checksums/signatures. 5. Pin installer downloads
to explicit versions. 6. Keep secrets and deployment credentials out of
source and build logs.

**Retest:** Builds are reproducible; dependency scan results are
reviewed; binary integrity is verified.

------------------------------------------------------------------------

## 4. Live validation results

Only low-volume, non-destructive HTTP GET checks were used against the
public instance.

  ------------------------------------------------------------------------
  Endpoint                 Observed result         Conclusion
  ------------------------ ----------------------- -----------------------
  `/api/status`            HTTP 200;               Public information
                           infrastructure and SSH  disclosure confirmed
                           metadata present        

  `/api/services`          HTTP 200; service       Public information
                           inventory, ports and    disclosure confirmed
                           states present          

  `/api/admin/processes`   HTTP 200; process       Public information
                           metadata present in     disclosure confirmed
                           earlier test            

  `/api/admin/tunnel`      HTTP 200; tunnel/SSH    Public information
                           metadata present in     disclosure confirmed
                           earlier test            

  `/api/admin/ports`       HTTP 200; port/service  Public information
                           metadata present in     disclosure confirmed
                           earlier test            

  `/files/api/files`       HTTP 200; empty listing Route reachable; no
                                                   file-content disclosure
                                                   demonstrated

  `/drop/api/clips`        HTTP 200; one entry     Unauthenticated
                           containing content      clipboard-entry
                                                   exposure confirmed;
                                                   content not inspected

  `/photos/api/photos`     HTTP 200; zero          Route reachable; no
                           photos/folders          photo disclosure
                                                   demonstrated

  `/cron/api/jobs`         HTTP 502                Inconclusive;
                                                   service/gateway
                                                   unavailable during test

  `/cron/api/history`      HTTP 502                Inconclusive;
                                                   service/gateway
                                                   unavailable during test
  ------------------------------------------------------------------------

These results describe the responses observed during testing and may
change as the deployment changes.

## 5. Tests deliberately not performed

The following were not performed against the public instance:

-   Executing a command through ChimpCron.
-   Uploading or serving an XSS proof-of-concept file.
-   Uploading, overwriting, renaming or deleting files.
-   Creating, modifying, pinning or deleting clipboard entries.
-   Uploading/deleting photos or triggering synchronization.
-   Brute force/password spraying.
-   High-volume requests, stress testing or denial-of-service testing.
-   SSH login attempts or internal network scanning.

These tests require an isolated copy with disposable data. Source-level
findings remain remediation priorities even without exploit execution.

## 6. Areas not verifiable from available access

No SSH, shell, Docker daemon or server-administration access was
available. Therefore, these areas were not verified:

-   Actual Linux user privileges and filesystem permissions.
-   Runtime Docker/container configuration and isolation.
-   Firewall/router configuration.
-   SSH daemon configuration and authentication policy.
-   Ngrok account/tunnel controls.
-   Exact deployed package versions and CVE exposure.
-   ChimpAI model server/tool execution security in depth.
-   ChimpSites tenant/site isolation in depth.
-   Runtime secrets, environment variables and backup permissions.

Repository configuration does not prove the deployed server matches the
repository.

## 7. Prioritized remediation plan

### Priority 0 --- Immediate containment

1.  Restrict public access to monitoring and administrative APIs.
2.  Disable or firewall ChimpCron until command execution is redesigned.
3.  Restrict public access to Drive, Drop and Pix until
    authentication/authorization is implemented.
4.  Replace any deployed default administrator password and rotate
    potentially exposed credentials.

### Priority 1 --- Core application security

1.  Implement authentication and per-operation authorization across
    APIs.
2.  Remove arbitrary shell command execution.
3.  Fix unsafe HTML rendering and inline event handlers.
4.  Add upload validation, limits and quotas.
5.  Restrict CORS to trusted origins.
6.  Add bounded process execution, output and concurrency controls.

### Priority 2 --- Defense in depth

1.  Pin and scan dependencies.
2.  Verify installer binary integrity.
3.  Harden Linux, SSH, Docker and firewall configuration.
4.  Add CSP, security headers and secure session controls.
5.  Add security-focused regression tests and monitoring.

### Priority 3 --- Retest

1.  Repeat anonymous API checks.
2.  Verify authorization for every read/write/admin operation.
3.  Validate path containment and upload restrictions.
4.  Validate XSS fixes with harmless markers in an isolated browser/test
    environment.
5.  Validate Cron allowlisting and process limits in an isolated
    environment.
6.  Perform controlled load/resilience tests only against an isolated
    instance.

## 8. Overall conclusion

The review identified a **critical command-execution design flaw** and
multiple high-risk unauthenticated API surfaces. Public monitoring
information disclosure and exposure of an existing clipboard entry were
confirmed on the live test instance. Other findings are supported by
source review but have not been independently exploited on the deployed
system.

**Security recommendation:** Do not treat the current deployment as safe
for unrestricted public exposure. Apply Priority 0 containment first,
remediate the application findings, then perform a controlled retest.

**Assessment limitation:** This is a preliminary source-code and limited
live-endpoint assessment, not a certification or a claim that every
possible vulnerability has been discovered.
