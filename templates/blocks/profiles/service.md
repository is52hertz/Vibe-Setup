<!-- PROFILE:service START -->
<PROFILE id="service">
**Profile: service / backend** — long-running services, APIs, anything with a datastore or external callers.
- Tests are required: cover new behavior; for a bug, first add a test that reproduces it, then make it pass.
- Validate and normalize every input crossing the trust boundary; never trust client-supplied values.
- **Data integrity & concurrency**: TODO — transactional boundaries, how concurrent writes are serialized, and idempotency for external callbacks. Fill in for this project.
</PROFILE>
<!-- PROFILE:service END -->
