#!/usr/bin/env bash
set -e

# Prevent interactive prompts from blocking non-interactive builds
export GIT_TERMINAL_PROMPT=0
git config --global user.name "${BUILD_USERNAME:-codebywin}" 2>/dev/null || true
git config --global user.email "${BUILD_USERNAME:-codebywin}@users.noreply.github.com" 2>/dev/null || true
git config --global color.ui false 2>/dev/null || true

echo "=========================================================="
echo " Starting Pixel 4 Build Script on Crave Devspace"
echo " Date: $(date)"
echo "=========================================================="

LUNCH_COMMAND="${1:-lunch lineage_flame-userdebug}"
BUILD_COMMAND="${2:-mka bacon}"
LOCAL_MANIFEST_URL="${3:-}"
LOCAL_MANIFEST_BRANCH="${4:-lineage-23.2}"
BUILD_USERNAME="${5:-codebywin}"
REMOVALS="${6:-}"
BUILD_DIFFERENT_ROM="${7:-echo 'Build Starting!'}"
REPO_REF="${8:-main}"
REPO_NAME="${9:-codebywin/test_build_rom_lineageOS_px4}"

if [ -z "$LOCAL_MANIFEST_URL" ]; then
    LOCAL_MANIFEST_URL="https://raw.githubusercontent.com/${REPO_NAME}/${REPO_REF}/manifests/flame_los23.xml"
fi

echo ">> Configuration:"
echo "   User:                  $BUILD_USERNAME"
echo "   Repository:            $REPO_NAME"
echo "   Repository ref:        $REPO_REF"
echo "   Lunch:                 $LUNCH_COMMAND"
echo "   Build Command:         $BUILD_COMMAND"
echo "   Manifest URL:          $LOCAL_MANIFEST_URL"
echo "   Manifest Branch:       $LOCAL_MANIFEST_BRANCH"
echo "   Removals:              $REMOVALS"

# 1. Clean manifests and removals if specified
if [ -n "$REMOVALS" ]; then
    echo ">> Removing specified folders: $REMOVALS"
    rm -rf .repo/local_manifests/ $REMOVALS
else
    rm -rf .repo/local_manifests/
fi

# 2. Local manifest & custom repo init
echo ">> Initializing repo & manifest..."
if [ -n "$BUILD_DIFFERENT_ROM" ] && [ "$BUILD_DIFFERENT_ROM" != "skip" ] && [ "$BUILD_DIFFERENT_ROM" != "echo 'Build Starting!'" ]; then
    echo ">> Running repo init override: $BUILD_DIFFERENT_ROM"
    eval "$BUILD_DIFFERENT_ROM" || true
fi

mkdir -p .repo/local_manifests
if [[ "$LOCAL_MANIFEST_URL" =~ \.xml(/)?$ ]]; then
    url="${LOCAL_MANIFEST_URL%/}"
    echo ">> Downloading manifest from $url..."
    tmp_manifest="/tmp/manifest_download.xml"
    curl -sL "$url" -o "$tmp_manifest"

    # Check if this is a full manifest (contains <default) or a local manifest
    if grep -q "<default" "$tmp_manifest"; then
        echo ">> Detected FULL manifest (contains <default). Replacing .repo/manifests/default.xml..."
        mkdir -p .repo/manifests
        cp "$tmp_manifest" .repo/manifests/default.xml
        # Clear local_manifests to avoid duplicate project errors
        rm -rf .repo/local_manifests/*
        # Ensure .repo/manifest.xml links to manifests/default.xml
        (cd .repo && ln -sf manifests/default.xml manifest.xml 2>/dev/null || true)
    else
        echo ">> Detected LOCAL manifest. Installing to .repo/local_manifests/local_manifest.xml..."
        cp "$tmp_manifest" .repo/local_manifests/local_manifest.xml
    fi
elif [[ "$LOCAL_MANIFEST_URL" =~ ^http || "$LOCAL_MANIFEST_URL" =~ ^git@ ]]; then
    echo ">> Cloning local manifest from $LOCAL_MANIFEST_URL (branch: $LOCAL_MANIFEST_BRANCH)..."
    git clone "$LOCAL_MANIFEST_URL" --depth 1 -b "$LOCAL_MANIFEST_BRANCH" .repo/local_manifests
elif [ -n "$LOCAL_MANIFEST_URL" ]; then
    echo ">> Running local manifest command: $LOCAL_MANIFEST_URL"
    eval "$LOCAL_MANIFEST_URL" || true
fi

# 3. Resync repositories
echo ">> Syncing repositories..."
if [ -f /usr/bin/resync ]; then
    /usr/bin/resync || true
else
    /opt/crave/resync.sh || true
fi

# 4. Set build environment
echo ">> Setting up build environment..."
export BUILD_USERNAME="$BUILD_USERNAME"
export BUILD_HOSTNAME="crave"
export WITH_DEXPREOPT=false
export WITH_DEXPREOPT_BOOT_IMG_AND_SYSTEM_SERVER_ONLY=false

sudo apt-get update && sudo apt-get install -y libncurses5 libtinfo5 || true
sudo ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null || true
sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5 2>/dev/null || true
sudo ln -sf /lib/x86_64-linux-gnu/libncurses.so.6 /lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null || true
sudo ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6 /lib/x86_64-linux-gnu/libtinfo.so.5 2>/dev/null || true

# 5. Clean git repositories thoroughly (reset tracked and remove untracked files) to prevent patch conflicts
echo ">> Cleaning git repos before patching..."
git -C frameworks/base reset --hard HEAD 2>/dev/null || true
git -C frameworks/base clean -fd 2>/dev/null || true

git -C system/core reset --hard HEAD 2>/dev/null || true
git -C system/core clean -fd 2>/dev/null || true

git -C device/google/coral reset --hard HEAD 2>/dev/null || true
git -C device/google/coral clean -fd 2>/dev/null || true

git -C device/google/flame reset --hard HEAD 2>/dev/null || true
git -C device/google/flame clean -fd 2>/dev/null || true

git -C build/make reset --hard HEAD 2>/dev/null || true
git -C build/make clean -fd 2>/dev/null || true

# 6. Configure BoardConfig.mk
if [ -f device/google/coral/BoardConfig.mk ]; then
    echo "WITH_DEXPREOPT := false" >> device/google/coral/BoardConfig.mk
    echo "WITH_DEXPREOPT_BOOT_IMG_AND_SYSTEM_SERVER_ONLY := false" >> device/google/coral/BoardConfig.mk
fi

# Helper function to apply a patch safely
apply_patch() {
    local target_dir="$1"
    local patch_name="$2"
    local patch_url="https://raw.githubusercontent.com/${REPO_NAME}/${REPO_REF}/patches/${patch_name}"
    local tmp_patch="/tmp/${patch_name}"

    echo ">> Fetching patch: ${patch_name} -> ${target_dir}"
    curl -sL "$patch_url" > "$tmp_patch"
    # FIX: Strip Windows CRLF line endings
    sed -i 's/\r$//' "$tmp_patch"
    # FIX: Strip UTF-8 BOM (EF BB BF) và chuỗi ký tự rác (∩╗┐: E2 88 A9 E2 95 97 E2 94 90)
    sed -i 's/\xef\xbb\xbf//g' "$tmp_patch"
    sed -i 's/\xe2\x88\xa9\xe2\x95\x97\xe2\x94\x90//g' "$tmp_patch"

    if git -C "$target_dir" apply --ignore-space-change --ignore-whitespace --check "$tmp_patch" >/dev/null 2>&1; then
        if git -C "$target_dir" apply --ignore-space-change --ignore-whitespace "$tmp_patch"; then
            echo "   [SUCCESS] Applied ${patch_name}"
        else
            echo "   [WARNING] Patch ${patch_name} check passed but apply failed, continuing..."
        fi
    else
        # Kiểm tra xem patch đã được apply từ trước chưa
        if git -C "$target_dir" apply --reverse --check "$tmp_patch" >/dev/null 2>&1; then
            echo "   [INFO] Patch ${patch_name} is already applied, skipping."
        else
            echo "   [WARNING] Patch ${patch_name} check failed! Details:"
            git -C "$target_dir" apply --ignore-space-change --ignore-whitespace --check "$tmp_patch" || true
        fi
    fi
}

# 7. Apply VCam patches for Android 16
echo ">> Applying VCam & SELinux patches for Android 16..."
apply_patch "frameworks/base" "vcam_pixel4_a16.patch"

# Fix Camera.java compatibility on Android 16 (remove final from overridden methods)
CAM_JAVA="frameworks/base/core/java/android/hardware/Camera.java"
if [ -f "$CAM_JAVA" ]; then
    echo ">> Patching Camera.java method signatures for VcamCamera compatibility on Android 16..."
    sed -i 's/public native final void setPreviewTexture/public native void setPreviewTexture/g' "$CAM_JAVA"
    sed -i 's/public native final void startPreview/public native void startPreview/g' "$CAM_JAVA"
    sed -i 's/public final void release/public void release/g' "$CAM_JAVA"
    sed -i 's/public final void setPreviewDisplay/public void setPreviewDisplay/g' "$CAM_JAVA"
    sed -i 's/public final void stopPreview/public void stopPreview/g' "$CAM_JAVA"
    sed -i 's/public final void setPreviewCallback/public void setPreviewCallback/g' "$CAM_JAVA"
fi

# Cài đặt trực tiếp SELinux policy cho VCam & Mic ảo vào device/google/coral (tránh lỗi git patch lệch dòng)
if [ -d "device/google/coral" ]; then
    echo ">> Configuring SELinux policy for VCam & Virtual Mic in device/google/coral..."
    mkdir -p device/google/coral/sepolicy/private
    mkdir -p device/google/coral/sepolicy/public

    cat << 'EOF' > device/google/coral/sepolicy/public/vcam.te
type vcam_data_file, file_type, data_file_type, core_data_file_type;
EOF

    cat << 'EOF' > device/google/coral/sepolicy/private/vcam.te
# Allow all apps (untrusted, system, platform) to access VCAM files
allow appdomain vcam_data_file:file { create read write open getattr setattr unlink map };
allow appdomain vcam_data_file:dir { create read write open getattr add_name remove_name search };

# Allow media framework services to access VCAM files
allow mediaserver vcam_data_file:file { read open getattr map };
allow mediaextractor vcam_data_file:file { read open getattr map };
allow audioserver vcam_data_file:file { read open getattr map };
allow hal_camera_default vcam_data_file:file { read open getattr map };

# Allow shell (adb) to manage VCAM files
allow shell vcam_data_file:file { create read write open getattr unlink rename setattr };
allow shell vcam_data_file:dir { create read write open getattr add_name remove_name search };
EOF

    touch device/google/coral/sepolicy/private/file_contexts
    if ! grep -q "vcam_data_file" device/google/coral/sepolicy/private/file_contexts; then
        cat << 'EOF' >> device/google/coral/sepolicy/private/file_contexts

# Virtual Camera & Virtual Mic files
/data/local/tmp/vcam.*                          u:object_r:vcam_data_file:s0
/data/local/tmp/vcam_.*                         u:object_r:vcam_data_file:s0
/data/local/tmp/vcam(/.*)?                      u:object_r:vcam_data_file:s0
EOF
        echo "   [SUCCESS] Appended VCam rules to sepolicy/private/file_contexts"
    else
        echo "   [INFO] VCam rules already exist in sepolicy/private/file_contexts"
    fi
fi

# 8. Release keys spoof in build system
echo ">> Setting release-keys in build/make..."
find build/make -name "sysprop.mk" -exec sed -i 's/BUILD_KEYS := test-keys/BUILD_KEYS := release-keys/g' {} + 2>/dev/null || true
find build/make -name "Makefile" -exec sed -i 's/BUILD_KEYS := test-keys/BUILD_KEYS := release-keys/g' {} + 2>/dev/null || true

# 9. Install CameraAssistant system app
echo ">> Setting up CameraAssistant app..."
mkdir -p packages/apps/CameraAssistant
curl -sL "https://raw.githubusercontent.com/${REPO_NAME}/${REPO_REF}/org.lineageos.camera.assistant/CameraAssistant.apk" > packages/apps/CameraAssistant/CameraAssistant.apk
curl -sL "https://raw.githubusercontent.com/${REPO_NAME}/${REPO_REF}/patches/CameraAssistant_Android.bp" > packages/apps/CameraAssistant/Android.bp
if [ -f device/google/coral/device.mk ]; then
    echo "PRODUCT_PACKAGES += CameraAssistant" >> device/google/coral/device.mk
fi
# FIX WARN#1: lineage_flame.mk thuộc device/google/flame/, KHÔNG phải device/google/coral/
if [ -f device/google/flame/lineage_flame.mk ]; then
    echo "PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += %/CameraAssistant.apk" >> device/google/flame/lineage_flame.mk
fi
if [ -f device/google/coral/lineage_coral.mk ]; then
    echo "PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += %/CameraAssistant.apk" >> device/google/coral/lineage_coral.mk
fi

# 12. Setup VCAM runtime control nodes in init.coral.rc
echo ">> Setting up VCAM control nodes in init.coral.rc..."
if [ -f device/google/coral/init.coral.rc ]; then
    cat << 'EOF' >> device/google/coral/init.coral.rc

on post-fs-data
    mkdir /data/local/tmp/vcam 0777 shell shell
    chmod 0777 /data/local/tmp
    write /data/local/tmp/vcam_pause 0
    write /data/local/tmp/vcam_disable 0
    write /data/local/tmp/vcam_mic_disable 0
    write /data/local/tmp/vcam_mic_mix 0
    write /data/local/tmp/vcam_kyc_flash 0
    write /data/local/tmp/vcam_color_sync 0
    write /data/local/tmp/vcam_rotation 0
    write /data/local/tmp/vcam_zoom 1.0
    write /data/local/tmp/vcam_pan_x 0.0
    write /data/local/tmp/vcam_pan_y 0.0
    write /data/local/tmp/vcam_pan.cfg 0.0,0.0
    write /data/local/tmp/vcam_mic_boost 1.0
    write /data/local/tmp/vcam_color_val normal
    write /data/local/tmp/vcam_reset 0
    chmod 0666 /data/local/tmp/vcam_pause
    chmod 0666 /data/local/tmp/vcam_disable
    chmod 0666 /data/local/tmp/vcam_mic_disable
    chmod 0666 /data/local/tmp/vcam_mic_mix
    chmod 0666 /data/local/tmp/vcam_kyc_flash
    chmod 0666 /data/local/tmp/vcam_color_sync
    chmod 0666 /data/local/tmp/vcam_rotation
    chmod 0666 /data/local/tmp/vcam_zoom
    chmod 0666 /data/local/tmp/vcam_pan_x
    chmod 0666 /data/local/tmp/vcam_pan_y
    chmod 0666 /data/local/tmp/vcam_pan.cfg
    chmod 0666 /data/local/tmp/vcam_mic_boost
    chmod 0666 /data/local/tmp/vcam_color_val
    chmod 0666 /data/local/tmp/vcam_reset
    # FIX NOTE#1: phải write tạo file trước rồi mới chmod được, tránh lỗi "No such file"
    write /data/local/tmp/vcam.mp4 ""
    write /data/local/tmp/vcam.wav ""
    chmod 0666 /data/local/tmp/vcam.mp4
    chmod 0666 /data/local/tmp/vcam.wav
EOF
fi

# 13. Source build environment and compile
echo ">> Sourcing build environment..."
source build/envsetup.sh
export LINEAGE_BUILDTYPE=RELEASE

# Tự động chuyển đổi lunch kiểu cũ (lineage_flame-userdebug) sang breakfast flame userdebug nếu có
if [[ "$LUNCH_COMMAND" =~ ^lunch\ lineage_([a-zA-Z0-9_]+)-(.*)$ ]]; then
    DEV="${BASH_REMATCH[1]}"
    TYPE="${BASH_REMATCH[2]}"
    echo ">> Legacy lunch format detected ($LUNCH_COMMAND). Converting to Lineage breakfast: breakfast $DEV $TYPE"
    LUNCH_COMMAND="breakfast $DEV $TYPE"
fi

echo ">> Running lunch/breakfast: $LUNCH_COMMAND"
eval "$LUNCH_COMMAND"

echo ">> Cleaning install artifacts: make installclean..."
make installclean || true

echo ">> Cleaning stale kernel obj to prevent Ninja restat timestamp conflicts..."
rm -rf out/target/product/*/obj/KERNEL_OBJ
rm -rf out/target/product/*/obj/DTBO_OBJ
rm -rf out/target/product/*/obj/PACKAGING/depmod*

echo ">> Starting compilation: $BUILD_COMMAND"
eval "$BUILD_COMMAND"

echo "=========================================================="
echo " Compilation Finished Successfully!"
echo " Date: $(date)"
echo "=========================================================="
