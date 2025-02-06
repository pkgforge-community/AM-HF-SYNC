#!/usr/bin/env bash
## <DO NOT RUN STANDALONE, meant for CI Only>
## Meant to Install AM Apps & Sync to HF
## Self: https://raw.githubusercontent.com/pkgforge-community/AM-HF-SYNC/refs/heads/main/.github/scripts/builder.sh
# bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge-community/AM-HF-SYNC/refs/heads/main/.github/scripts/builder.sh")
#-------------------------------------------------------#

#-------------------------------------------------------#
##Sanity
export TZ="UTC"
#GH
 if [[ "${GHA_MODE}" != "MATRIX" ]]; then
   echo -e "[-] FATAL: This Script only Works on Github Actions\n"
  exit 1
 fi
#Input
 if [[ -z "${PKG_NAME+x}" ]]; then
   echo -e "[-] FATAL: Package Name '\${PKG_NAME}' is NOT Set\n"
  exit 1 
 fi
#Host
 if [[ -z "${HOST_TRIPLET+x}" ]]; then
  HOST_TRIPLET="$(uname -m)-$(uname -s)"
  HOST_TRIPLET_L="${HOST_TRIPLET,,}"
  export HOST_TRIPLET HOST_TRIPLET_L
 fi
#Script
 if [[ "${HOST_TRIPLET}" == "aarch64-Linux" ]]; then
   BUILD_SCRIPT="https://github.com/ivan-hc/AM/blob/main/programs/aarch64/${PKG_NAME}"
 elif [[ "${HOST_TRIPLET}" == "x86_64-Linux" ]]; then
   BUILD_SCRIPT="https://github.com/ivan-hc/AM/blob/main/programs/x86_64/${PKG_NAME}"
 fi
 BUILD_SCRIPT_RAW="$(echo "${BUILD_SCRIPT}" | sed 's|/blob/main|/raw/main|' | tr -d '[:space:]')"
#Tmp
 if [[ ! -d "${SYSTMP}" ]]; then
  SYSTMP="$(dirname $(mktemp -u))" && export SYSTMP
 fi
#User-Agent
 if [[ -z "${USER_AGENT+x}" ]]; then
  USER_AGENT="$(curl -qfsSL 'https://pub.ajam.dev/repos/Azathothas/Wordlists/Misc/User-Agents/ua_chrome_macos_latest.txt')"
 fi
#Path
 export PATH="${HOME}/bin:${HOME}/.cargo/bin:${HOME}/.cargo/env:${HOME}/.go/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/miniconda3/bin:${HOME}/miniconda3/condabin:/usr/local/zig:/usr/local/zig/lib:/usr/local/zig/lib/include:/usr/local/musl/bin:/usr/local/musl/lib:/usr/local/musl/include:${PATH}"
 PATH="$(echo "${PATH}" | awk 'BEGIN{RS=":";ORS=":"}{gsub(/\n/,"");if(!a[$0]++)print}' | sed 's/:*$//')" ; export PATH
#Cleanup 
 unset GH_TOKEN GITHUB_TOKEN HF_TOKEN
#-------------------------------------------------------#

#-------------------------------------------------------#
##Main
pushd "$(mktemp -d)" &>/dev/null && \
  BUILD_DIR="$(realpath .)" && \
  git clone --depth="1" --filter="blob:none" --no-checkout "https://huggingface.co/datasets/pkgforge/AMcache" && \
  cd "./AMcache" && HF_REPO_DIR="$(realpath .)"
  [[ -d "${HF_REPO_DIR}" ]] || echo -e "\n[-] FATAL: Failed to create ${HF_REPO_DIR}\n $(exit 1)"
  git lfs install &>/dev/null ; huggingface-cli lfs-enable-largefiles "." &>/dev/null
  HF_PKGPATH="${HF_REPO_DIR}/${PKG_NAME}/${HOST_TRIPLET}"
  mkdir -pv "${HF_PKGPATH}" ; git fetch origin main ; git lfs track "./${PKG_NAME}/${HOST_TRIPLET}/**"
  git sparse-checkout set "" ; git sparse-checkout set --no-cone --sparse-index ".gitattributes"
  git checkout ; ls -lah "." "./${PKG_NAME}/${HOST_TRIPLET}" ; git sparse-checkout list
  #Install
   {
     echo -e "\n[+] Installing ${PKG_NAME} ...\n"
     timeout -k 5s 10s curl -w "\n(Script) <== %{url}\n" -qfsSL "${BUILD_SCRIPT_RAW}"
     set -x
     timeout -k 10s 300s am install --debug "${PKG_NAME}"
     timeout -k 10s 300s am files "${PKG_NAME}" | cat -
     timeout -k 10s 300s am about "${PKG_NAME}" | cat -
   } 2>&1 | ts -s '[%H:%M:%S]➜ ' | tee "${BUILD_DIR}/${PKG_NAME}.log"
  #Check
   if [[ -f "/opt/${PKG_NAME}/${PKG_NAME}" ]] && [[ $(stat -c%s "/opt/${PKG_NAME}/${PKG_NAME}") -gt 1024 ]]; then
     echo "BUILD_SUCCESSFUL=YES" >> "${GITHUB_ENV}"
     #Prep
      pushd "${HF_PKGPATH}" &>/dev/null && \
       #Version
        PKG_VERSION="$(sed -n 's/.*version *: *\([^ ]*\).*/\1/p' "${BUILD_DIR}/${PKG_NAME}.log" | tr -d '[:space:]')"
        if [ -z "${PKG_VERSION+x}" ] || [ -z "${PKG_VERSION##*[[:space:]]}" ]; then
          if grep -qi "github.com" "/opt/${PKG_NAME}/version"; then
            PKG_VERSION="$(sed -E 's#.*/download/([^/]+)/.*#\1#' "/opt/${PKG_NAME}/version" | tr -d '[:space:]')"
          else
            PKG_VERSION="latest"
          fi
        fi
       #Dir
        HF_PKGPATH="${HF_PKGPATH}/${PKG_VERSION}"
        mkdir -pv "${HF_PKGPATH}" && echo "HF_PKGPATH=${HF_PKGPATH}" >> "${GITHUB_ENV}"
        if [[ -d "${HF_PKGPATH}" ]]; then
          pushd "${HF_PKGPATH}" &>/dev/null
          HF_PKGNAME="${PKG_NAME}/${HOST_TRIPLET}/${PKG_VERSION}"
        else
          echo -e "\n[-] FATAL: Failed to create ${HF_PKGPATH}\n"
         exit 1 
        fi
       #Pkg
        cp -fv "/opt/${PKG_NAME}/${PKG_NAME}" "${HF_PKGPATH}/${PKG_NAME}"
        if [[ -f "${HF_PKGPATH}/${PKG_NAME}" ]] && [[ $(stat -c%s "${HF_PKGPATH}/${PKG_NAME}") -gt 5 ]]; then
         PKG_NAME="${PKG_NAME}"
         echo -e "[+] Name: ${PKG_NAME} ('.pkg_name')"
         PKG_DOWNLOAD_URL="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/${PKG_NAME}"
         echo -e "[+] Download URL: ${PKG_DOWNLOAD_URL} ('.download_url')"
         if grep -m1 -qi "appimage" "${BUILD_DIR}/${PKG_NAME}.log"; then
           PKG_TYPE="appimage"
           echo -e "[+] Type: ${PKG_TYPE} ('.pkg_type')"
         fi
        fi
       #Info
        timeout -k 10s 300s am about "${PKG_NAME}" 2>/dev/null | cat -> "${HF_PKGPATH}/${PKG_NAME}.txt"
       #Build Date
        PKG_DATETMP="$(date --utc +%Y-%m-%dT%H:%M:%S)Z"
        PKG_BUILD_DATE="$(echo "${PKG_DATETMP}" | sed 's/ZZ\+/Z/Ig')"
        echo -e "[+] Build Date: ${PKG_BUILD_DATE} ('.build_date')"
       #Build GH
        PKG_BUILD_GHA="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
        PKG_BUILD_ID="${GITHUB_RUN_ID}"
       #Build Log
        cp -fv "${BUILD_DIR}/${PKG_NAME}.log" "${HF_PKGPATH}/${PKG_NAME}.log"
        if [[ -f "${HF_PKGPATH}/${PKG_NAME}.log" ]] && [[ $(stat -c%s "${HF_PKGPATH}/${PKG_NAME}.log") -gt 5 ]]; then
         PKG_BUILD_LOG="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/${PKG_NAME}.log"
         echo -e "[+] Build Log: ${PKG_BUILD_LOG} ('.build_log')"
        fi
       #Build Script 
        curl -qfsSL "${BUILD_SCRIPT_RAW}" -o "${HF_PKGPATH}/AM_SCRIPT"
        if [[ -f "${HF_PKGPATH}/AM_SCRIPT" ]] && [[ $(stat -c%s "${HF_PKGPATH}/AM_SCRIPT") -gt 5 ]]; then
         PKG_BUILD_SCRIPT="${BUILD_SCRIPT}"
         #PKG_BUILD_SCRIPT="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/AM_SCRIPT"
         echo -e "[+] Build Script: ${PKG_BUILD_SCRIPT} ('.build_script')"
        fi
       #Checksums
        PKG_BSUM="$(b3sum "${HF_PKGPATH}/${PKG_NAME}" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
        echo -e "[+] B3SUM: ${PKG_BSUM} ('.bsum')"
        PKG_SHASUM="$(sha256sum "${HF_PKGPATH}/${PKG_NAME}" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
        echo -e "[+] SHA256SUM: ${PKG_SHASUM} ('.shasum')"
       #Description
        if [ -z "${PKG_DESCRIPTION+x}" ] || [ -z "${PKG_DESCRIPTION##*[[:space:]]}" ]; then
          PKG_DESCRIPTION="$(awk 'BEGIN {IGNORECASE=1}
             /version:/ {f=1; next}
             /site:/ {f=0}
             f {sub(/.*]➜[[:space:]]*/, ""); sub(/^[[:space:].]+/, ""); sub(/[[:space:].]+$/, ""); if (NF) print}' "${BUILD_DIR}/${PKG_NAME}.log" 2>/dev/null)"
          echo -e "[+] Description: ${PKG_DESCRIPTION} ('.description')"
        fi
       #Desktop
        DESKTOP_FILE="$(find '/usr/local/share/applications/' -type f -iname "*${PKG_NAME}*AM*desktop" -print | sort -u | head -n 1 | tr -d '[:space:]')"
        if [[ -f "${DESKTOP_FILE}" ]] && [[ $(stat -c%s "${DESKTOP_FILE}") -gt 5 ]]; then
         sed '/.*DBusActivatable.*/I d' -i "${DESKTOP_FILE}"
         sed -E 's/\s+setup\s+/ /Ig' -i "${DESKTOP_FILE}"
         sed "s/Icon=[^ ]*/Icon=${PKG}/" -i "${DESKTOP_FILE}"
         cp -fv "${DESKTOP_FILE}" "${HF_PKGPATH}/${PKG_NAME}.desktop"
         if [[ -f "${HF_PKGPATH}/${PKG_NAME}.desktop" ]] && [[ $(stat -c%s "${HF_PKGPATH}/${PKG_NAME}.desktop") -gt 5 ]]; then
           PKG_DESKTOP="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/${PKG_NAME}.desktop"
           echo -e "[+] Desktop: ${PKG_DESKTOP} ('.desktop')"
         fi
        fi
       #Homepage
        PKG_HOMEPAGE="$(grep -o 'http[s]\?://[^"]*' "${HF_PKGPATH}/${PKG_NAME}.txt" | tr -d '"' | grep -iv "github.com" | head -n 1 | tr -d '[:space:]')"
        PKG_HOMEPAGE_GH="$(grep -o 'http[s]\?://[^"]*' "${HF_PKGPATH}/${PKG_NAME}.txt" | tr -d '"' | grep -i "github.com" | head -n 1 | tr -d '[:space:]')"
        if echo "${PKG_HOMEPAGE_GH}" | grep -qi 'http'; then
          PKG_HOMEPAGE="${PKG_HOMEPAGE_GH}"
          PKG_SRC_URL="${PKG_HOMEPAGE_GH}"
        elif echo "${PKG_HOMEPAGE}" | grep -qE 'http'; then
          PKG_HOMEPAGE="${PKG_HOMEPAGE}"
          PKG_SRC_URL="${PKG_HOMEPAGE}"
        else
          PKG_HOMEPAGE=""
          PKG_SRC_URL=""
        fi
        echo -e "[+] Homepage: ${PKG_HOMEPAGE} ('.homepage')"
       #Icon
        ICON_FILE="$(find "/opt/${PKG_NAME}/icons" -type f -exec stat --format="%s %n" "{}" + | sort -nr | head -n1 | sed 's/^[0-9]\+[[:space:]]\+//')"
        if [[ -f "${ICON_FILE}" ]] && [[ $(stat -c%s "${ICON_FILE}") -gt 5 ]]; then
          ICON_TYPE="$(file -i "${ICON_FILE}")"
           if echo "${ICON_TYPE}" | grep -qiE 'image/(png)'; then
             cp -fv "${ICON_FILE}" "${HF_PKGPATH}/${PKG_NAME}.png"
             if [[ -f "${HF_PKGPATH}/${PKG_NAME}.png" ]] && [[ $(stat -c%s "${HF_PKGPATH}/${PKG_NAME}.png") -gt 5 ]]; then
               PKG_ICON="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/${PKG_NAME}.png"
             fi
           elif echo "${ICON_TYPE}" | grep -qiE 'image/(svg)'; then
             cp -fv "${ICON_FILE}" "${HF_PKGPATH}/${PKG_NAME}.svg"
             if [[ -f "${HF_PKGPATH}/${PKG_NAME}.svg" ]] && [[ $(stat -c%s "${HF_PKGPATH}/${PKG_NAME}.svg") -gt 5 ]]; then
               PKG_ICON="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/${PKG_NAME}.svg"
             fi
           elif echo "${ICON_TYPE}" | grep -qE 'image/(jpeg|jpg)'; then
             cp -fv "${ICON_FILE}" "${HF_PKGPATH}/${PKG_NAME}.jpg"
             if [[ -f "${HF_PKGPATH}/${PKG_NAME}.jpg" ]] && [[ $(stat -c%s "${HF_PKGPATH}/${PKG_NAME}.jpg") -gt 5 ]]; then
               PKG_ICON="https://huggingface.co/datasets/pkgforge/AMcache/resolve/main/${HF_PKGNAME}/${PKG_NAME}.jpg"
             fi
           fi
         echo -e "[+] Icon: ${PKG_ICON} ('.icon')"
        fi
       #Size
        PKG_SIZE_RAW="$(stat --format="%s" "${HF_PKGPATH}/${PKG_NAME}" | tr -d '[:space:]')"
        PKG_SIZE="$(du -sh "${HF_PKGPATH}/${PKG_NAME}" | awk '{unit=substr($1,length($1)); sub(/[BKMGT]$/,"",$1); print $1 " " unit "B"}')"
        echo -e "[+] Size: ${PKG_SIZE} ('.size')"
        echo -e "[+] Size (Raw): ${PKG_SIZE_RAW} ('.size_raw')"
    #Generate Json
     jq -n --arg HOST "${HOST_TRIPLET}" \
       --arg PKG "${PKG_NAME}" \
       --arg PKG_ID "AM.$(uname -m).${PKG_NAME}" \
       --arg PKG_NAME "${PKG_NAME,,}" \
       --arg PKG_TYPE "${PKG_TYPE}" \
       --arg BSUM "${PKG_BSUM}" \
       --arg BUILD_DATE "${PKG_BUILD_DATE}" \
       --arg BUILD_GHA "${PKG_BUILD_GHA}" \
       --arg BUILD_ID "${PKG_BUILD_ID}" \
       --arg BUILD_LOG "${PKG_BUILD_LOG}" \
       --arg BUILD_SCRIPT "${PKG_BUILD_SCRIPT}" \
       --arg DESCRIPTION "${PKG_DESCRIPTION}" \
       --arg DESKTOP "${PKG_DESKTOP}" \
       --arg DOWNLOAD_URL "${PKG_DOWNLOAD_URL}" \
       --arg HOMEPAGE "${PKG_HOMEPAGE}" \
       --arg ICON "${PKG_ICON}" \
       --arg PROVIDES "${PKG_NAME,,}" \
       --arg SHASUM "${PKG_SHASUM}" \
       --arg SIZE "${PKG_SIZE}" \
       --arg SIZE_RAW "${PKG_SIZE_RAW}" \
       --arg SRC_URL "${PKG_SRC_URL}" \
       --arg VERSION "${PKG_VERSION}" \
       '
        {
          _disabled: ("false"),
          host: $HOST,
          pkg: $PKG,
          pkg_id: $PKG_ID,
          pkg_name: $PKG_NAME,
          pkg_type: $PKG_TYPE,
          bsum: $BSUM,
          build_date: $BUILD_DATE,
          build_gha: $BUILD_GHA,
          build_id: $BUILD_ID,
          build_log: $BUILD_LOG,
          build_script: $BUILD_SCRIPT,
          description: (
           if (.description // "") == "" 
           then $DESCRIPTION | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | gsub("^\\s+|\\s+$"; "") | gsub("^\\.+|\\.+$"; "") 
           else .description | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | gsub("^\\s+|\\s+$"; "") | gsub("^\\.+|\\.+$"; "") 
           end
          ),
          desktop: $DESKTOP,
          download_url: $DOWNLOAD_URL,
          homepage: [$HOMEPAGE],
          icon: $ICON,
          maintainer: [
          "AM (https://github.com/ivan-hc/AM)"
          ],
          note: [
          "[EXTERNAL] We CAN NOT guarantee the authenticity, validity or security",
          "This package was auto-built, cached & uploaded using AM",
          "Provided by: https://github.com/ivan-hc/AM",
          "Please create an Issue or send a PR for an official Package",
          "Repo: https://github.com/pkgforge/soarpkgs"
          ],
          provides: [$PROVIDES],
          shasum: $SHASUM,
          size: $SIZE,
          size_raw: $SIZE_RAW,
          src_url: [$SRC_URL],
          version: $VERSION
        }
       ' | jq 'walk(if type == "object" then with_entries(select(.value != null and .value != "")) | select(length > 0) elif type == "array" then map(select(. != null and . != "")) | select(length > 0) else . end)' > "${BUILD_DIR}/${PKG_NAME}.json"
    #Copy Json
     if jq -r '.pkg' "${BUILD_DIR}/${PKG_NAME}.json" | grep -iv 'null' | tr -d '[:space:]' | grep -Eiq "^${PKG_NAME}$"; then
       cp -fv "${BUILD_DIR}/${PKG_NAME}.json" "${HF_PKGPATH}/${PKG_NAME}.json"
     fi
    #Sync
     pushd "${HF_REPO_DIR}" &>/dev/null && \
       git pull origin main --ff-only ; git merge --no-ff -m "Merge & Sync"
       git lfs track "./${HF_PKGNAME}/**"
       if [ -d "${HF_PKGPATH}" ] && [ "$(du -s "${HF_PKGPATH}" | cut -f1)" -gt 100 ]; then
         find "${HF_PKGPATH}" -type f -size -3c -delete
         git sparse-checkout add "${HF_PKGNAME}"
         git sparse-checkout list
         git add --all --verbose && git commit -m "[+] PKG [${HF_PKGNAME}] (${PKG_VERSION})"
         git pull origin main ; git push origin main #&& sleep "$(shuf -i 500-4500 -n 1)e-3"
         git --no-pager log '-1' --pretty="format:'%h - %ar - %s - %an'"
         if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
          echo -e "\n[-] WARN: Failed to push ==> ${HF_PKGNAME}/${PKG_VERSION}\n(Retrying ...)\n"
          git pull origin main ; git push origin main #&& sleep "$(shuf -i 500-4500 -n 1)e-3"
          git --no-pager log '-1' --pretty="format:'%h - %ar - %s - %an'"
          if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
            echo -e "\n[-] FATAL: Failed to push ==> ${HF_PKGNAME}/${PKG_VERSION}\n"
          fi
         fi
         du -sh "${HF_PKGPATH}" && realpath "${HF_PKGPATH}"
       fi
     pushd "${TMPDIR}" &>/dev/null
   else
     echo -e "\n[-] FATAL: Failed to Build ${PKG_NAME}\n"
     echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
     echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
   fi
##Cleanup
popd &>/dev/null
#-------------------------------------------------------#

#-------------------------------------------------------#
#Cleanup Dir  
 if [ -n "${GITHUB_TEST_BUILD+x}" ]; then
  7z a -t7z -mx="9" -mmt="$(($(nproc)+1))" -bsp1 -bt "/tmp/BUILD_ARTIFACTS.7z" "${HF_PKGPATH}" 2>/dev/null
 elif [[ "${KEEP_LOGS}" != "YES" ]]; then
  echo -e "\n[-] Removing ALL Logs & Files\n"
  rm -rvf "${HF_PKGPATH}" 2>/dev/null
 fi
#-------------------------------------------------------# 