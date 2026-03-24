# Not yet run

# Future Improvements

- Add support for apt packages (.deb)

# Already run

- If we wanted to allow the user to upload a private and public GPG key pair, how difficult would it be for us to automatically sign the RPMs they upload so they don't have to do it before uploading?  would that be bad security?

- Does rpm support private repos?  For example, can it be configured to pass an API key with the request that we could use to allow hosting private packages that require auth to download?

- Some additional thoughts that may or may not already be reflected in the design doc:
  - Each repo can have multiple packages in it.  For example if I create repo freedomben, I can upload packages for applications called termigate, emoji-spa, etc. so user's don't have to add a new repo for every package
  - Users who aren't uploading packages don't need to authenticate in either the web ui or the API to get a read-only view and download rpm files.

- These are the major features we want to have:
  - Web interface:
    - for creating new repos
    - for browsing existing repos
    - for getting setup instructions for adding a repo to a user's dnf
    - for viewing a list of available packages
    - for setup instructions for installing a package
    - for authenticated user's to upload new RPM versions
  - REST API for:
    - programmatically doing anything the web interface supports
  - RPM files are stored in object storage (backblaze b2), sent to the user's dnf as signed URLs with a 30 minute access window
  - web app renders the needed responses and metadata for the repos, basically everything except the rpm files itself

- In this repo, we want to create an app called Dark Zenith.  This should be an Elixir/Phoenix app that that can effectively serve as an rpm repo for use with any RPM-based distro. It would serve the repo metadata and the rpm files, and also provide an admin interface and API for managing it.   It would also serve a user-facing webpage that provides users instructions for adding the repo to their local distro, as well as show a list of available packages and provide links to download them.  Let's begin by writing up a detailed application description in PRODUCT_DESIGN.md
