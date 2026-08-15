CSE 489: Mobile Application Development
Lab Exam — Smart Geo-Tagged Landmarks App

=========================================
PROJECT OVERVIEW
=========================================
This is a Flutter mobile application designed to manage, visit, visual-map, and filter Smart Geo-Tagged Landmarks. The app integrates with a faculty-provided backend REST API with key 24341171, maintains a local cache database (SQLite/Room equivalent via sqflite), synchronizes offline queued requests on internet availability, and polls asynchronous visit jobs using WorkManager background workers.

=========================================
FEATURES IMPLEMENTED
=========================================
1. Bottom Navigation Tabs:
   - Map: Initialized centered on Bangladesh (Latitude: 23.6850, Longitude: 90.3563, Zoom: 7). Visualizes landmarks using custom-colored markers representing the landmark score (Red for cold/low score to Green for warm/high score). Clicking a marker displays landmark details in a premium bottom-sheet callout.
   - Landmarks: Displays all landmarks in a list format, supporting score sorting (Ascending/Descending) and filtering by a minimum score threshold. Image placeholders and error-fallbacks are used for missing/broken image assets.
   - Activity: Displays history of landmark visits with name, timestamp, resolved distance, status (queued, pending, done, failed), and error messages.
   - Add/View: Coordinates form populated automatically with user's current GPS location on load. Includes manual coordinate fetching, image picking, and form validations.
2. Visit Feature: Visits retrieve the user's current GPS coordinates and submit them to the visit endpoint. The application extracts the pending job ID, registers a background task with WorkManager to poll the job status asynchronously, and updates the local cache state and UI.
3. Offline Caching & Queueing: All landmarks are cached locally. Visited landmarks while offline are queued and automatically synced/drained when connectivity is restored.

=========================================
API USAGE
=========================================
- Base URL: https://labs.anontech.info/cse489/exm3/api.php
- Endpoints integrated:
  1. Get Landmarks: GET ?action=get_landmarks&key=24341171
  2. Visit Landmark: POST ?action=visit_landmark&key=24341171
  3. Get Job Status: GET ?action=get_job_status&key=24341171&job_id=JOB_ID
  4. Create Landmark: POST ?action=create_landmark&key=24341171 (using Multipart FormData)
  5. Delete Landmark: POST ?action=delete_landmark&key=24341171 (using x-www-form-urlencoded)
  6. Restore Landmark: POST ?action=restore_landmark&key=24341171 (using x-www-form-urlencoded)

=========================================
OFFLINE STRATEGY
=========================================
- SQLite local database stores the cached landmarks and pending job queue.
- If network connection is missing during a visit action, the request is written to `pending_visits` (representing the Room Entity `PendingVisit`) with a `'queued'` status and a WorkManager task is scheduled with network constraints.
- In the foreground, a connectivity stream listener triggers the queue drain immediately upon restoring internet connectivity.
- A periodic database state monitor (timer) refreshes the user interface dynamically in the foreground when any job resolves.

=========================================
ARCHITECTURE USED
=========================================
- Repository and Single-Source-of-Truth Pattern: The database serves as the local cache representing the application state. Background workers and state managers write updates to SQLite, and UI observes state and database streams via the Provider state management package.

=========================================
CHALLENGES FACED
=========================================
1. Multipart Boundary Issues: Custom `Content-Type: multipart/form-data` header overrides without boundary tags resulted in empty file uploads on the PHP backend. Removing manual header overrides allowed Dio to generate boundaries, resolving landmark image uploads.
2. Multi-Visit Mapping: When the same landmark was visited multiple times, updating visits by `landmark_id` updated duplicate entries. Resolving visits by a unique `local_id` autoincrement primary key mapped to `visit_id` in `pending_visits` solved the duplicate update issue.
