#!/usr/bin/env bash
#
# This script automates the process of fetching Android 16 Beta OTA files for Pixel 8 (shiba),
# patching them with Magisk (optional) and other modules, and then releasing them
# on GitHub and updating an OTA server (typically GitHub Pages).
#
# To run this script, make sure it has execute permissions:
# chmod +x rooted-ota-android16.sh
#
# Required tools: git, jq, curl, docker (for patching)
#
# Environment Variables:
#   KEY_AVB, KEY_OTA, CERT_OTA: Paths to AVB and OTA signing keys/certs (default: avb.key, ota.key, ota.crt)
#   KEY_AVB_BASE64, KEY_OTA_BASE64, CERT_OTA_BASE64: Base64 encoded keys/certs (if not using files)
#   PASSPHRASE_AVB, PASSPHRASE_OTA: Passphrases for keys (if not set, will be queried interactively)
#   DEBUG: Set to 'true' for verbose debug output (set -x)
#   DEVICE_ID: The device ID (e.g., 'shiba'). Defaults to 'shiba' for Android 16 Beta OTA.
#   GITHUB_TOKEN: GitHub Personal Access Token for API access.
#   GITHUB_REPO: GitHub repository in 'owner/repo' format (e.g., 'your-username/your-repo').
#   MAGISK_PREINIT_DEVICE: Set if you want a Magisk-patched OTA (e.g., 'shiba_beta').
#   SKIP_ROOTLESS: Set to 'true' to skip creating the rootless OTA.
#   OTA_VERSION: Will be dynamically determined from the fetched OTA filename.
#   MAGISK_VERSION: Specific Magisk version (default: v28.1). Set to 'latest' to fetch the newest.
#   SKIP_CLEANUP: Set to 'true' to skip cleaning up temporary files.
#   FORCE_OTA_SERVER_UPLOAD: Set to 'true' to force updating OTA server data even if version exists.
#   FORCE_BUILD: Set to 'true' to force building artifacts even if they exist on release.
#   SKIP_OTA_SERVER_UPLOAD: Set to 'true' to skip updating the OTA server (overrides FORCE_OTA_SERVER_UPLOAD).
#   UPLOAD_TEST_OTA: Set to 'true' to upload OTA to a 'test/' folder on the OTA server.
#   NO_COLOR: Set to 'true' to disable colored output.
#

# --- Configuration Variables ---
KEY_AVB=${KEY_AVB:-avb.key}
KEY_OTA=${KEY_OTA:-ota.key}
CERT_OTA=${CERT_OTA:-ota.crt}

KEY_AVB_BASE64=${KEY_AVB_BASE64:-''}
KEY_OTA_BASE64=${KEY_OTA_BASE64:-''}
CERT_OTA_BASE64=${CERT_OTA_BASE64:-''}

DEBUG=${DEBUG:-''}
if [[ -n "${DEBUG}" ]]; then set -x; fi

DEVICE_ID=${DEVICE_ID:-}
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_REPO=${GITHUB_REPO:-''}

MAGISK_PREINIT_DEVICE=${MAGISK_PREINIT_DEVICE:-}
SKIP_ROOTLESS=${SKIP_ROOTLESS:-'false'}
OTA_VERSION=${OTA_VERSION:-'latest'} # This will be updated dynamically

DEFAULT_MAGISK_VERSION=v28.1
MAGISK_VERSION=${MAGISK_VERSION:-${DEFAULT_MAGISK_VERSION}}

SKIP_CLEANUP=${SKIP_CLEANUP:-''}
FORCE_OTA_SERVER_UPLOAD=${FORCE_OTA_SERVER_UPLOAD:-'false'}
FORCE_BUILD=${FORCE_BUILD:-'false'}
SKIP_OTA_SERVER_UPLOAD=${SKIP_OTA_SERVER_UPLOAD:-'false'}
UPLOAD_TEST_OTA=${UPLOAD_TEST_OTA:-false}

NO_COLOR=${NO_COLOR:-''}

# Base URL for downloading the Android 16 Beta OTA file
ANDROID_16_BETA_DOWNLOAD_BASE_URL="https://dl.google.com/developers/android/baklava/images/ota/"
ANDROID_16_BETA_PAGE_URL="https://developer.android.com/about/versions/16/download-ota"

# Tool versions (renovatebot compatible comments kept)
# renovate: datasource=github-releases packageName=chenxiaolong/avbroot versioning=semver
AVB_ROOT_VERSION=3.15.0
# renovate: datasource=github-releases packageName=chenxiaolong/Custota versioning=semver-coerced
CUSTOTA_VERSION=5.7
# renovate: datasource=git-refs packageName=https://github.com/chenxiaolong/my-avbroot-setup currentValue=master
PATCH_PY_COMMIT=16636c3
# renovate: datasource=docker packageName=python
PYTHON_VERSION=3.13.2-alpine
# renovate: datasource=github-releases packageName=chenxiaolong/OEMUnlockOnBoot versioning=semver-coerced
OEMUNLOCKONBOOT_VERSION=1.1
# renovate: datasource=github-releases packageName=chenxiaolong/afsr versioning=semver
AFSR_VERSION=1.0.3

CHENXIAOLONG_PK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
GIT_PUSH_RETRIES=10

# --- Global Variables (managed by functions) ---
declare -A POTENTIAL_ASSETS # Stores a map of flavor (magisk/rootless) to expected asset filename
RELEASE_ID=''               # Stores the GitHub release ID if it exists or is created
OTA_TARGET=''               # Stores the full OTA filename (e.g., shiba_beta-ota-....zip)
OTA_URL=''                  # Stores the full URL to download the OTA file

# --- Script Setup ---
set -o nounset -o pipefail -o errexit # Exit on unset variables, pipe failures, and errors

# --- Utility Functions ---

# Prints a message with a timestamp.
function print() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}

# Prints a green message with a timestamp.
function printGreen() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[32m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}

# Prints a red message with a timestamp and indicates an error.
function printRed() {
  if [[ -z "${NO_COLOR}" ]]; then
   echo -e "\e[31m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}

# Checks if mandatory environment variables are set.
# Args:
#   $@: List of variable names to check.
function checkMandatoryVariable() {
  for var_name in "$@"; do
    local var_value="${!var_name}"
    if [[ -z "$var_value" ]]; then
      printRed "Missing mandatory param: $var_name"
      exit 1
    fi
  done
}

# Creates a suffix for asset filenames based on UPLOAD_TEST_OTA and git status.
# Returns:
#   A string suffix (e.g., '-test', '-dirty', '-test-dirty').
function createAssetSuffix() {
  local suffix=''
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    suffix+='-test'
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    suffix+='-dirty'
  fi
  echo "$suffix"
}

# Converts base64 encoded keys/certs from environment variables back to files.
function base642key() {
  set +x # Don't expose secrets to log
  mkdir -p .tmp # Ensure .tmp directory exists for keys
  if [ -n "$KEY_AVB_BASE64" ]; then
    echo "$KEY_AVB_BASE64" | base64 -d >.tmp/$KEY_AVB
    KEY_AVB=.tmp/$KEY_AVB
  fi

  if [ -n "$KEY_OTA_BASE64" ]; then
    echo "$KEY_OTA_BASE64" | base64 -d >.tmp/$KEY_OTA
    KEY_OTA=.tmp/$KEY_OTA
  fi

  if [ -n "$CERT_OTA_BASE64" ]; then
    echo "$CERT_OTA_BASE64" | base64 -d >.tmp/$CERT_OTA
    CERT_OTA=.tmp/$CERT_OTA
  fi
  if [[ -n "${DEBUG}" ]]; then set -x; fi # Re-enable debug if it was on
}

# Pushes changes to the gh-pages branch with retries.
function gitPushWithRetries() {
  local count=0
  print "Attempting to push to gh-pages with retries..."
  while [ $count -lt $GIT_PUSH_RETRIES ]; do
    git pull --rebase
    if git push origin gh-pages; then
      printGreen "Successfully pushed to gh-pages."
      break
    else
      count=$((count + 1))
      printGreen "Retry $count/$GIT_PUSH_RETRIES failed. Retrying in 2 seconds..."
      sleep 2
    fi
  done
  
  if [ $count -eq $GIT_PUSH_RETRIES ]; then
    printRed "Failed to push to gh-pages after $GIT_PUSH_RETRIES attempts."
    exit 1
  fi
}

# Cleans up temporary files and unsets sensitive variables.
function cleanup() {
  print "Cleaning up temporary files and environment variables..."
  rm -rf .tmp
  unset KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
  print "Cleanup complete."
}

# --- Core Logic Functions ---

# Downloads a release artifact from chenxiaolong's GitHub repositories and verifies it.
# Args:
#   $1: Repository name (e.g., 'avbroot', 'Custota', 'afsr').
#   $2: Version number (e.g., '3.15.0').
#   $3: Optional artifact name (defaults to repo name if not provided, e.g., 'custota-tool').
function downloadAndVerifyFromChenxiaolong() {
  local repo="$1"
  local version="$2"
  local artifact="${3:-$1}" # Defaults to repo name if not provided
  
  local url="https://github.com/chenxiaolong/${repo}/releases/download/v${version}/${artifact}-${version}-x86_64-unknown-linux-gnu.zip"
  local downloadedZipFile
  downloadedZipFile="$(mktemp)"
  
  mkdir -p .tmp

  if ! ls ".tmp/${artifact}" >/dev/null 2>&1; then
    print "Downloading and verifying ${artifact} from ${url}..."
    curl --fail -sL "${url}" > "${downloadedZipFile}"
    curl --fail -sL "${url}.sig" > "${downloadedZipFile}.sig"
    
    # Validate against author's public key
    if ! ssh-keygen -Y verify -I chenxiaolong -f <(echo "chenxiaolong $CHENXIAOLONG_PK") -n file \
      -s "${downloadedZipFile}.sig" < "${downloadedZipFile}"; then
      printRed "Signature verification failed for ${artifact}!"
      exit 1
    fi
    printGreen "Signature verification successful for ${artifact}."
    
    echo N | unzip "${downloadedZipFile}" -d .tmp # 'N' for no to overwrite existing files
    rm "${downloadedZipFile}"* # Clean up downloaded zip and signature
    chmod +x ".tmp/${artifact}" # Make the extracted tool executable
  else
    printGreen "${artifact} already exists locally, skipping download."
  fi
}

# Fetches the latest Android 16 Beta OTA filename and determines the OTA_VERSION and OTA_URL.
function findLatestVersion() {
  # For Android 16 Beta, we're specifically looking for 'shiba_beta-ota' files.
  # Ensure DEVICE_ID is 'shiba' for consistent naming in assets.
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="shiba"
    printGreen "DEVICE_ID not set. Defaulting to 'shiba' as the script is fetching shiba_beta-ota files."
  elif [[ "$DEVICE_ID" != "shiba" ]]; then
    printRed "Warning: DEVICE_ID is set to '$DEVICE_ID', but the script is configured to fetch 'shiba_beta-ota' files." \
             "This might lead to inconsistencies in asset naming or unexpected behavior."
  fi

  # Determine the latest Magisk version if 'latest' is specified
  if [[ "$MAGISK_VERSION" == 'latest' ]]; then
    print "Fetching latest Magisk version..."
    MAGISK_VERSION=$(curl --fail -sL -I -o /dev/null -w '%{url_effective}' https://github.com/topjohnwu/Magisk/releases/latest | sed 's/.*\/tag\///;')
    printGreen "Latest Magisk version: $MAGISK_VERSION"
  fi

  print "Fetching Android 16 Beta OTA page: $ANDROID_16_BETA_PAGE_URL"
  local page_content
  page_content=$(curl -s "$ANDROID_16_BETA_PAGE_URL")

  if [ $? -ne 0 ]; then
      printRed "Error fetching page: $ANDROID_16_BETA_PAGE_URL"
      exit 1
  fi

  local found_ota_filename
  # Regex to find text starting with "shiba_beta-ota" and ending with ".zip"
  found_ota_filename=$(echo "$page_content" | grep -oE "shiba_beta-ota[^<]*?\.zip" | head -n 1)

  if [ -z "$found_ota_filename" ]; then
      printRed "Could not find the OTA filename starting with 'shiba_beta-ota' on the page."
      exit 1
  fi

  print "Found OTA filename: $found_ota_filename"

  # Extract the version (e.g., 2025052100) from the filename for use as OTA_VERSION
  # This assumes the format is always shiba_beta-ota-YYYYMMDDHH-....zip
  OTA_VERSION=$(echo "$found_ota_filename" | grep -oP "shiba_beta-ota-\K\d{10}")

  if [ -z "$OTA_VERSION" ]; then
      printRed "Could not extract OTA version from filename: $found_ota_filename"
      exit 1
  fi

  print "Extracted OTA version for release tagging: $OTA_VERSION"

  # Set OTA_TARGET to the full filename. This will be used for local file storage.
  OTA_TARGET="$found_ota_filename"

  # Construct the full download URL using the new base URL
  OTA_URL="${ANDROID_16_BETA_DOWNLOAD_BASE_URL}${found_ota_filename}"

  printGreen "OTA target filename: $OTA_TARGET; Download URL: $OTA_URL"
}

# Checks if building new assets is necessary based on existing GitHub releases.
function checkBuildNecessary() {
  local currentCommit
  currentCommit=$(git rev-parse --short HEAD)
  POTENTIAL_ASSETS=() # Reset potential assets for this run
    
  # Define potential asset names based on flavors (magisk/rootless)
  if [[ -n "$MAGISK_PREINIT_DEVICE" ]]; then 
    POTENTIAL_ASSETS['magisk']="${DEVICE_ID}-${OTA_VERSION}-magisk-${MAGISK_VERSION}$(createAssetSuffix).zip"
  else 
    printGreen "MAGISK_PREINIT_DEVICE not set, not creating magisk OTA."
  fi
  
  if [[ "$SKIP_ROOTLESS" != 'true' ]]; then
    POTENTIAL_ASSETS['rootless']="${DEVICE_ID}-${OTA_VERSION}-rootless$(createAssetSuffix).zip"
  else
    printGreen "SKIP_ROOTLESS set, not creating rootless OTA."
  fi

  RELEASE_ID='' # Reset release ID
  local response

  if [[ -z "$GITHUB_REPO" ]]; then
    print "Env Var GITHUB_REPO not set, skipping check for existing release."
    return
  fi

  print "Checking for existing GitHub release with tag: ${OTA_VERSION}"

  local params=()
  local url="https://api.github.com/repos/${GITHUB_REPO}/releases"

  if [ -n "${GITHUB_TOKEN}" ]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi
  params+=("-H" "Accept: application/vnd.github.v3+json")

  response=$(curl --fail -sL "${params[@]}" "${url}" | \
             jq --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | {id, tag_name, name, published_at, assets}')

  if [[ -n ${response} ]]; then
    RELEASE_ID=$(echo "${response}" | jq -r '.id')
    printGreen "Release ${OTA_VERSION} exists. ID=$RELEASE_ID"
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      print "Checking if asset '${POTENTIAL_ASSET_NAME}' exists in release..."
      
      # Check if an asset with the same device-version prefix and flavor already exists
      local selectedAsset
      selectedAsset=$(echo "${response}" | jq -r --arg assetPrefix "${DEVICE_ID}-${OTA_VERSION}" \
        '.assets[] | select(.name | startswith($assetPrefix)) | .name' \
          | grep "${flavor}" || true)
  
      if [[ -n "${selectedAsset}" ]] && [[ "$FORCE_BUILD" != 'true' ]] && [[ "$UPLOAD_TEST_OTA" != 'true' ]]; then
        printGreen "Skipping build of asset name '$POTENTIAL_ASSET_NAME'. An asset for this flavor already exists in the release." \
          "Set FORCE_BUILD or UPLOAD_TEST_OTA to force. Existing asset: ${selectedAsset//$'\n'/ }"
        unset "POTENTIAL_ASSETS[$flavor]" # Remove from the list of assets to build
      else
        print "No existing asset found with name '$POTENTIAL_ASSET_NAME' (or build is forced)."
      fi
    done
    
    if [ "${#POTENTIAL_ASSETS[@]}" -eq 0 ]; then
      printGreen "All potential assets already exist in the release. Exiting script."
      exit 0 # Exit if nothing needs to be built
    fi
  else
    print "Release ${OTA_VERSION} does not exist. A new one will be created."
  fi
}

# Downloads all necessary Android dependencies (Magisk, OTA zip).
function downloadAndroidDependencies() {
  checkMandatoryVariable 'MAGISK_VERSION' 'OTA_TARGET' # OTA_TARGET is the full filename

  mkdir -p .tmp
  
  # Download Magisk APK if needed
  if ! ls ".tmp/magisk-$MAGISK_VERSION.apk" >/dev/null 2>&1 && [[ "${POTENTIAL_ASSETS['magisk']+isset}" ]]; then
    print "Downloading Magisk APK (version: $MAGISK_VERSION)..."
    curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" "https://github.com/1q23lyc45/KitsuneMagisk/releases/latest/download/app-release.apk"
    printGreen "Magisk APK downloaded."
  else
    printGreen "Magisk APK already exists or not required for this build."
  fi

  # Download the Android 16 Beta OTA zip
  if ! ls ".tmp/$OTA_TARGET" >/dev/null 2>&1; then
    print "Downloading Android 16 Beta OTA file: $OTA_TARGET from $OTA_URL..."
    curl --fail -sLo ".tmp/$OTA_TARGET" "$OTA_URL"
    printGreen "Android 16 Beta OTA file downloaded."
  else
    printGreen "Android 16 Beta OTA file already exists locally."
  fi
}

# Patches the downloaded OTA file with Magisk and other modules using avbroot.
function patchOTAs() {
  print "Starting OTA patching process..."
  downloadAndVerifyFromChenxiaolong 'avbroot' "$AVB_ROOT_VERSION"
  downloadAndVerifyFromChenxiaolong 'afsr' "$AFSR_VERSION" 'afsr' # Specify artifact name for clarity

  # Download Custota and OEMUnlockOnBoot zips if not present
  if ! ls ".tmp/custota.zip" >/dev/null 2>&1; then
    print "Downloading Custota zip..."
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip" > .tmp/custota.zip
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip.sig" > .tmp/custota.zip.sig
    printGreen "Custota zip downloaded."
  else
    printGreen "Custota zip already exists."
  fi

  if ! ls ".tmp/oemunlockonboot.zip" >/dev/null 2>&1; then
    print "Downloading OEMUnlockOnBoot zip..."
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip" > .tmp/oemunlockonboot.zip
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip.sig" > .tmp/oemunlockonboot.zip.sig
    printGreen "OEMUnlockOnBoot zip downloaded."
  else
    printGreen "OEMUnlockOnBoot zip already exists."
  fi

  # Clone my-avbroot-setup if not present
  if ! ls ".tmp/my-avbroot-setup" >/dev/null 2>&1; then
    print "Cloning my-avbroot-setup repository..."
    git clone https://github.com/chenxiaolong/my-avbroot-setup .tmp/my-avbroot-setup
    (cd .tmp/my-avbroot-setup && git checkout ${PATCH_PY_COMMIT})
    printGreen "my-avbroot-setup cloned."
  else
    printGreen "my-avbroot-setup already exists."
  fi

  base642key # Convert base64 keys from env vars to files if needed

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local targetFile=".tmp/${POTENTIAL_ASSETS[$flavor]}"

    if ls "$targetFile" >/dev/null 2>&1; then
      printGreen "Patched file $targetFile already exists locally, skipping patching for this flavor."
    else
      print "Patching OTA for flavor: ${flavor} -> ${targetFile}"
      local args=()

      args+=("--output" "$targetFile")
      args+=("--input" ".tmp/$OTA_TARGET") # Use OTA_TARGET (full filename) as input
      args+=("--sign-key-avb" "$KEY_AVB")
      args+=("--sign-key-ota" "$KEY_OTA")
      args+=("--sign-cert-ota" "$CERT_OTA")

      if [[ "$flavor" == 'magisk' ]]; then
        args+=("--patch-arg=--magisk" "--patch-arg" ".tmp/magisk-$MAGISK_VERSION.apk")
        args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "$MAGISK_PREINIT_DEVICE")
      fi

      # Passphrases via environment variables if set
      if [ -v PASSPHRASE_AVB ]; then
        args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
      fi
      if [ -v PASSPHRASE_OTA ]; then
        args+=("--pass-ota-env-var" "PASSPHRASE_OTA")
      fi

      args+=("--module-custota" ".tmp/custota.zip")
      args+=("--module-oemunlockonboot" ".tmp/oemunlockonboot.zip")
      args+=("--skip-custota-tool") # We handle custota-tool separately

      # Run patch.py in a Docker container to ensure consistent environment
      docker run --rm -v "$PWD:/app" -v "$PWD/.tmp:/app/.tmp" -w /app \
        -e PATH='/bin:/usr/local/bin:/sbin:/usr/bin/:/app/.tmp' \
        -e PASSPHRASE_AVB="$PASSPHRASE_AVB" -e PASSPHRASE_OTA="$PASSPHRASE_OTA" \
        python:${PYTHON_VERSION} sh -c \
          "apk add openssh && \
           pip install -r .tmp/my-avbroot-setup/requirements.txt && \
           python .tmp/my-avbroot-setup/patch.py ${args[*]} && \
           chown -R $(id -u):$(id -g) .tmp" # Chown back files created by root in container
    
       printGreen "Finished patching file ${targetFile}"
    fi
  done
}

# Uploads a file as a GitHub release asset.
# Args:
#   $1: Source file path.
#   $2: Target filename for the asset.
#   $3: Content type (e.g., 'application/zip').
function uploadFile() {
  local sourceFileName="$1"
  local targetFileName="$2"
  local contentType="$3"

  print "Uploading asset: $targetFileName from $sourceFileName (Content-Type: $contentType)..."
  curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$targetFileName"
  printGreen "Asset $targetFileName uploaded successfully."
}

# Creates a GitHub release and uploads the patched OTA files as assets.
function releaseOta() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN' 'OTA_VERSION'

  local response changelog
  if [[ -z "$RELEASE_ID" ]]; then
    print "Creating new GitHub release for tag: $OTA_VERSION..."
    # Generate release notes using GitHub API
    changelog=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$OTA_VERSION\",
              \"target_commitish\": \"main\"
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases/generate-notes" | jq -r '.body // empty')
    
    # Prepend custom message to changelog
    changelog="Update to [Android 16 Beta ${OTA_VERSION}](https://developer.android.com/about/versions/16/download-ota).\n\n$(echo "${changelog}" | sed ':a;N;$!ba;s/\n/\\n/g')"
    
    # Create the new release
    response=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$OTA_VERSION\",
              \"target_commitish\": \"main\",
              \"name\": \"$OTA_VERSION\",
              \"body\": \"${changelog}\",
              \"draft\": false,
              \"prerelease\": true
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases")
    
    RELEASE_ID=$(echo "${response}" | jq -r '.id // empty')
    if [[ -n "${RELEASE_ID}" ]]; then
      printGreen "Release created successfully with ID: ${RELEASE_ID}"
    elif echo "${response}" | jq -e '.status == "422"' > /dev/null; then
      # Handle case where release might have been created concurrently
      print "Release for ${OTA_VERSION} might have been created concurrently. Attempting to find it..."
      RELEASE_ID=$(curl -sL \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases" | \
            jq -r --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | .id // empty')
      if [[ -n "${RELEASE_ID}" ]]; then
        printGreen "Found existing release for ${OTA_VERSION}. ID=$RELEASE_ID"
      else
        printRed "Cannot create release for ${OTA_VERSION} and could not find an existing one."
        exit 1
      fi
    else
      errors=$(echo "${response}" | jq -r '.errors')
      printRed "Failed to create release for ${OTA_VERSION}. Errors: ${errors}"
      exit 1
    fi
  fi

  # Upload all potential assets to the release
  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    uploadFile ".tmp/$assetName" "$assetName" "application/zip"
  done
}

# Creates OTA server data (.csig and .json files) using custota-tool.
function createOtaServerData() {
  print "Creating OTA server data..."
  downloadAndVerifyFromChenxiaolong 'Custota' "$CUSTOTA_VERSION" 'custota-tool' # Ensure custota-tool is downloaded

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
    local targetFile=".tmp/${POTENTIAL_ASSET_NAME}"
    
    print "Generating .csig for ${POTENTIAL_ASSET_NAME}..."
    local csig_args=()
    csig_args+=("--input" "${targetFile}")
    csig_args+=("--output" "${targetFile}.csig")
    csig_args+=("--key" "$KEY_OTA")
    csig_args+=("--cert" "$CERT_OTA")
    if [ -v PASSPHRASE_OTA ]; then
      csig_args+=("--passphrase-env-var" "PASSPHRASE_OTA")
    fi
    .tmp/custota-tool gen-csig "${csig_args[@]}"
    printGreen ".csig generated for ${POTENTIAL_ASSET_NAME}."
  
    mkdir -p ".tmp/${flavor}" # Create flavor-specific temp directory
    
    print "Generating update info JSON for ${flavor}..."
    local json_args=()
    json_args+=("--file" ".tmp/${flavor}/${DEVICE_ID}.json")
    # Construct the download location for the OTA file on GitHub releases
    json_args+=("--location" "https://github.com/$GITHUB_REPO/releases/download/$OTA_VERSION/$POTENTIAL_ASSET_NAME")
  
    .tmp/custota-tool gen-update-info "${json_args[@]}"
    printGreen "Update info JSON generated for ${flavor}."
  done
}

# Uploads OTA server data to the gh-pages branch of the GitHub repository.
function uploadOtaServerData() {
  print "Uploading OTA server data to GitHub Pages..."
  local current_branch current_commit current_author
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  current_commit=$(git rev-parse --short HEAD)
  current_author=$(git log -1 --format="%an <%ae>")
  folderPrefix=''
  
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    folderPrefix='test/' # Use a 'test/' subfolder for test OTAs
  fi

  git checkout gh-pages # Switch to gh-pages branch

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
    local targetJsonFile="${folderPrefix}${flavor}/${DEVICE_ID}.json"
    local tempJsonSourceFile=".tmp/${flavor}/$DEVICE_ID.json"

    # Upload the .csig file as a release asset (it's part of the release, not gh-pages)
    uploadFile ".tmp/${POTENTIAL_ASSET_NAME}.csig" "$POTENTIAL_ASSET_NAME.csig" "application/octet-stream"
    
    mkdir -p "${folderPrefix}${flavor}" # Ensure target directory exists on gh-pages

    # Check if the OTA server data needs to be updated
    if ! grep -q "$OTA_VERSION" "${targetJsonFile}" || [[ "$FORCE_OTA_SERVER_UPLOAD" == 'true' ]] && [[ "$SKIP_OTA_SERVER_UPLOAD" != 'true' ]]; then
      print "Updating OTA server data for ${flavor} at ${targetJsonFile}..."
      cp "$tempJsonSourceFile" "${targetJsonFile}"
      git add "${targetJsonFile}"
      printGreen "OTA server data updated for ${flavor}."
    elif grep -q "${OTA_VERSION}" "${targetJsonFile}"; then
      printGreen "Skipping update of OTA server for ${flavor}, because ${OTA_VERSION} already in ${targetJsonFile} and FORCE_OTA_SERVER_UPLOAD is false."
    else
      printGreen "Skipping update of OTA server for ${flavor}, because SKIP_OTA_SERVER_UPLOAD is true."
    fi
  done
  
  # Commit and push changes if there are any
  if ! git diff-index --quiet HEAD; then
    print "Committing changes to gh-pages..."
    git config user.name "GitHub Actions" && git config user.email "actions@github.com" # Configure git user
    git commit \
        --message "Update device $DEVICE_ID basing on commit $current_commit" \
        --author="$current_author"
  
    gitPushWithRetries # Push with retries
  else
    printGreen "No changes to commit on gh-pages."
  fi

  # Switch back to the original branch
  git checkout "$current_branch"
  printGreen "Switched back to branch: $current_branch"
}

# --- Main Execution Flow ---
function main() {
  # Set up cleanup trap to run on exit or error
  [[ "$SKIP_CLEANUP" != 'true' ]] && trap cleanup EXIT ERR

  # 1. Find the latest Android 16 Beta OTA version and URL
  findLatestVersion

  # 2. Check if a build is necessary (based on existing GitHub releases)
  checkBuildNecessary

  # 3. Download Android dependencies (Magisk, OTA zip)
  downloadAndroidDependencies

  # 4. Patch the OTA files
  patchOTAs

  # 5. Release the patched OTAs on GitHub
  releaseOta

  # 6. Create OTA server data (.csig and .json files)
  createOtaServerData

  # 7. Upload OTA server data to GitHub Pages
  uploadOtaServerData

  printGreen "Script execution completed successfully!"
}

# Call the main function to start the process
main
