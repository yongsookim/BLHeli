#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  Raspberry Pi 5 + Hailo AI HAT+ + NVMe SSD                  ║
# ║  YOLO11 완전 자동 설치 프로그램                               ║
# ║                                                              ║
# ║  이 파일 하나만 실행하면 모든 설치가 완료됩니다.              ║
# ║                                                              ║
# ║  실행 방법:                                                   ║
# ║    sudo bash pi5_yolo11_install.sh                           ║
# ╚══════════════════════════════════════════════════════════════╝

set -e

# ── 설정 ──────────────────────────────────────────────────────────────────────
MOUNT_USER="${SUDO_USER:-kimyongsoo}"
MOUNT_PATH="/media/$MOUNT_USER/PI5_SSD"
VENV_DIR="/home/$MOUNT_USER/hailo_env"
CONFIG_FILE="/boot/firmware/config.txt"
STATE_FILE="/var/lib/pi5-yolo11-install.stage"
LOG_FILE="/var/log/pi5_yolo11_install.log"
SCRIPT_PATH="$(realpath "$0")"

# ── 색상 ──────────────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'
B='\033[1m'; NC='\033[0m'

ok()  { echo -e "${G}  ✔ $1${NC}" | tee -a "$LOG_FILE"; }
warn(){ echo -e "${Y}  ⚠ $1${NC}" | tee -a "$LOG_FILE"; }
err() { echo -e "${R}  ✘ $1${NC}" | tee -a "$LOG_FILE"; }
hdr() { echo -e "\n${C}${B}▶ $1${NC}" | tee -a "$LOG_FILE"; }
log() { echo "$1" | tee -a "$LOG_FILE"; }

# ── root 확인 ─────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "root 권한이 필요합니다."
    echo "  실행 방법: sudo bash $0"
    exit 1
fi

# ── 현재 단계 확인 ────────────────────────────────────────────────────────────
STAGE=1
[ -f "$STATE_FILE" ] && STAGE=$(cat "$STATE_FILE")

# ═════════════════════════════════════════════════════════════════════════════
# 헤더 출력
# ═════════════════════════════════════════════════════════════════════════════
clear
echo "" | tee -a "$LOG_FILE"
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
echo -e "${B}║  YOLO11 완전 자동 설치  |  단계: $STAGE / 2                     ║${NC}" | tee -a "$LOG_FILE"
echo -e "${B}║  Raspberry Pi 5 + Hailo AI HAT+ + NVMe SSD                  ║${NC}" | tee -a "$LOG_FILE"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
echo -e "  사용자: $MOUNT_USER  |  로그: $LOG_FILE" | tee -a "$LOG_FILE"
date | tee -a "$LOG_FILE"


# ═════════════════════════════════════════════════════════════════════════════
# 1단계: 하드웨어 설정 (재부팅 필요)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" -eq 1 ]; then

    echo -e "\n${B}  ┌─────────────────────────────────────────┐${NC}"
    echo -e "${B}  │  1단계: 하드웨어 설정 (재부팅 후 자동으로  │${NC}"
    echo -e "${B}  │         2단계가 실행됩니다)               │${NC}"
    echo -e "${B}  └─────────────────────────────────────────┘${NC}"

    # ── PCIe Gen3 활성화 ───────────────────────────────────────────────────
    hdr "PCIe Gen3 활성화 (NVMe SSD 고속 통신)"
    if grep -q "^dtparam=pciex1_gen=3" "$CONFIG_FILE"; then
        ok "PCIe Gen3 이미 설정됨"
    else
        echo "dtparam=pciex1_gen=3" >> "$CONFIG_FILE"
        ok "PCIe Gen3 활성화 추가"
    fi

    # ── NVMe SSD 설정 ──────────────────────────────────────────────────────
    hdr "NVMe SSD 감지 및 설정"
    modprobe nvme 2>/dev/null || true
    NVME_DEV=""
    for dev in /dev/nvme0n1 /dev/nvme1n1; do
        [ -b "$dev" ] && NVME_DEV="$dev" && break
    done

    if [ -z "$NVME_DEV" ]; then
        warn "NVMe 장치 미감지 → 재부팅 후 자동 재시도"
        warn "SSD가 M.2 슬롯에 올바르게 삽입됐는지 확인하세요."
    else
        ok "NVMe 장치 감지: $NVME_DEV"
        NVME_PART="${NVME_DEV}p1"

        if ! [ -b "$NVME_PART" ]; then
            log "  파티션 생성 중..."
            parted -s "$NVME_DEV" mklabel gpt
            parted -s "$NVME_DEV" mkpart primary ext4 0% 100%
            sleep 1; partprobe "$NVME_DEV"; sleep 1
            mkfs.ext4 -L "PI5_SSD" -F "$NVME_PART"
            ok "ext4 파티션 생성 및 포맷 완료"
        else
            ok "기존 파티션 사용: $NVME_PART"
        fi

        mkdir -p "$MOUNT_PATH"
        mountpoint -q "$MOUNT_PATH" && umount "$MOUNT_PATH" || true
        mount "$NVME_PART" "$MOUNT_PATH"
        chown -R "$MOUNT_USER:$MOUNT_USER" "$MOUNT_PATH"
        ok "SSD 마운트 완료: $MOUNT_PATH"

        UUID=$(blkid -o value -s UUID "$NVME_PART")
        if ! grep -q "$UUID" /etc/fstab; then
            { echo ""; echo "# NVMe SSD – PI5_SSD"
              echo "UUID=$UUID  $MOUNT_PATH  ext4  defaults,noatime,nofail  0  2"; } >> /etc/fstab
            ok "부팅 시 자동 마운트 등록 완료 (fstab)"
        fi
    fi

    # ── Raspberry Pi AI Camera (IMX500) ───────────────────────────────────
    hdr "Raspberry Pi AI Camera (IMX500) 드라이버"
    apt-get update -qq
    apt-get install -y libcamera-dev libcamera-tools python3-libcamera \
        python3-picamera2 python3-kms++ python3-prctl curl wget -qq
    if dpkg -l imx500-all &>/dev/null; then
        ok "imx500-all 이미 설치됨"
    else
        apt-get install -y imx500-all -qq && ok "IMX500 드라이버 설치 완료" || \
            warn "IMX500 설치 실패 – RPi AI Camera 미사용 시 무시"
    fi

    # ── Arducam UC-261 (IMX519) ────────────────────────────────────────────
    hdr "Arducam UC-261 (IMX519) 드라이버 (자동초점)"
    if grep -q "dtoverlay=imx519" "$CONFIG_FILE"; then
        ok "dtoverlay=imx519 이미 설정됨"
    else
        echo "dtoverlay=imx519" >> "$CONFIG_FILE"
        ok "dtoverlay=imx519 추가됨"
    fi
    curl -fsSL https://github.com/ArduCAM/Arducam-Pivariety-V4L2-Driver/releases/download/install_script/install_pivariety_pkgs.sh \
        | bash -s -- -p imx519_standalone_driver 2>/dev/null && \
        ok "Arducam IMX519 드라이버 설치 완료" || \
        warn "Arducam 자동 설치 실패 – 표준 드라이버로 동작 시도"

    # ── 2단계 자동 실행 서비스 등록 ───────────────────────────────────────
    hdr "재부팅 후 2단계 자동 실행 등록"
    cat > /etc/systemd/system/pi5-yolo11-install.service << EOF
[Unit]
Description=Pi5 YOLO11 Install Stage 2
After=network-online.target
Wants=network-online.target
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable pi5-yolo11-install.service
    echo "2" > "$STATE_FILE"
    ok "자동 실행 서비스 등록 완료"

    # ── 재부팅 안내 ────────────────────────────────────────────────────────
    echo ""
    echo -e "${Y}${B}  ┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${Y}${B}  │  ★ 1단계 완료! 재부팅이 필요합니다.             │${NC}"
    echo -e "${Y}${B}  │    재부팅 후 2단계가 자동으로 실행됩니다.        │${NC}"
    echo -e "${Y}${B}  └─────────────────────────────────────────────────┘${NC}"
    echo ""
    read -r -p "  지금 재부팅할까요? [Y/n]: " ANS
    ANS="${ANS:-Y}"
    if [[ "$ANS" =~ ^[Yy]$ ]]; then
        log "재부팅 중..."; sleep 1; reboot
    else
        echo "  나중에 직접 재부팅: sudo reboot"
    fi
    exit 0
fi


# ═════════════════════════════════════════════════════════════════════════════
# 2단계: 소프트웨어 설치 (재부팅 후 자동 실행)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" -eq 2 ]; then

    echo -e "\n${B}  ┌─────────────────────────────────────────┐${NC}"
    echo -e "${B}  │  2단계: 소프트웨어 설치                   │${NC}"
    echo -e "${B}  └─────────────────────────────────────────┘${NC}"

    # ── SSD 마운트 확인 ────────────────────────────────────────────────────
    hdr "SSD 마운트 확인"
    if mountpoint -q "$MOUNT_PATH"; then
        ok "SSD 마운트 확인: $MOUNT_PATH"
    else
        mount -a 2>/dev/null && ok "SSD 마운트 완료" || warn "SSD 마운트 실패 – 수동 확인 필요"
    fi

    # ── 시스템 패키지 ──────────────────────────────────────────────────────
    hdr "시스템 패키지 설치"
    apt-get update -qq
    apt-get install -y \
        python3-pip python3-venv python3-dev \
        libopencv-dev python3-opencv \
        libatlas-base-dev libhdf5-dev \
        ffmpeg v4l-utils -qq
    ok "시스템 패키지 설치 완료"

    # ── Python 가상환경 ────────────────────────────────────────────────────
    hdr "Python 가상환경 생성"
    if [ ! -d "$VENV_DIR" ]; then
        sudo -u "$MOUNT_USER" python3 -m venv "$VENV_DIR" --system-site-packages
        ok "가상환경 생성: $VENV_DIR"
    else
        ok "가상환경 이미 존재: $VENV_DIR"
    fi
    PIP="$VENV_DIR/bin/pip"
    PY="$VENV_DIR/bin/python3"

    # ── Python 패키지 ──────────────────────────────────────────────────────
    hdr "Python 패키지 설치"
    sudo -u "$MOUNT_USER" "$PIP" install --upgrade pip -q
    sudo -u "$MOUNT_USER" "$PIP" install -q opencv-python-headless numpy
    ok "Python 패키지 설치 완료"

    sudo -u "$MOUNT_USER" "$PY" -c "import hailo_platform" 2>/dev/null && \
        ok "hailo_platform 사용 가능" || \
        warn "hailo_platform 미설치 – Hailo Suite 별도 설치 필요"

    sudo -u "$MOUNT_USER" "$PY" -c "import picamera2" 2>/dev/null && \
        ok "picamera2 사용 가능" || \
        warn "picamera2 접근 불가 – sudo apt install python3-picamera2"

    # ── HEF 모델 다운로드 ──────────────────────────────────────────────────
    hdr "YOLO11 HEF 모델 다운로드 (Hailo-8L)"
    MODEL_DIR="$MOUNT_PATH/models"
    mkdir -p "$MODEL_DIR"
    BASE="https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8l"
    for M in yolov11n yolov11s; do
        OUT="$MODEL_DIR/${M/yolov/yolo}.hef"
        if [ ! -f "$OUT" ]; then
            log "  다운로드: $M ..."
            wget -q --show-progress -O "$OUT" "$BASE/${M}.hef" && \
                ok "$M 다운로드 완료" || { warn "$M 다운로드 실패"; rm -f "$OUT"; }
        else
            ok "$M 이미 존재"
        fi
    done

    # ── SSD 디렉토리 구조 생성 ─────────────────────────────────────────────
    hdr "SSD 데이터 디렉토리 구조 생성"
    if mountpoint -q "$MOUNT_PATH"; then
        for split in train val test; do
            mkdir -p "$MOUNT_PATH/dataset/images/$split"
            mkdir -p "$MOUNT_PATH/dataset/labels/$split"
        done
        mkdir -p "$MOUNT_PATH/detections" "$MOUNT_PATH/videos" \
                 "$MOUNT_PATH/images"     "$MOUNT_PATH/logs"

        CLASSES=(
            "00_person"        "01_bicycle"       "02_car"
            "03_motorcycle"    "04_airplane"      "05_bus"
            "06_train"         "07_truck"         "08_boat"
            "09_traffic_light" "10_fire_hydrant"  "11_stop_sign"
            "12_parking_meter" "13_bench"         "14_bird"
            "15_cat"           "16_dog"           "17_horse"
            "18_sheep"         "19_cow"           "20_elephant"
            "21_bear"          "22_zebra"         "23_giraffe"
            "24_backpack"      "25_umbrella"      "26_handbag"
            "27_tie"           "28_suitcase"      "29_frisbee"
            "30_skis"          "31_snowboard"     "32_sports_ball"
            "33_kite"          "34_baseball_bat"  "35_baseball_glove"
            "36_skateboard"    "37_surfboard"     "38_tennis_racket"
            "39_bottle"        "40_wine_glass"    "41_cup"
            "42_fork"          "43_knife"         "44_spoon"
            "45_bowl"          "46_banana"        "47_apple"
            "48_sandwich"      "49_orange"        "50_broccoli"
            "51_carrot"        "52_hot_dog"       "53_pizza"
            "54_donut"         "55_cake"          "56_chair"
            "57_couch"         "58_potted_plant"  "59_bed"
            "60_dining_table"  "61_toilet"        "62_tv"
            "63_laptop"        "64_mouse"         "65_remote"
            "66_keyboard"      "67_cell_phone"    "68_microwave"
            "69_oven"          "70_toaster"       "71_sink"
            "72_refrigerator"  "73_book"          "74_clock"
            "75_vase"          "76_scissors"      "77_teddy_bear"
            "78_hair_drier"    "79_toothbrush"
        )
        for cls in "${CLASSES[@]}"; do
            mkdir -p "$MOUNT_PATH/guide_photos/$cls"
        done
        chown -R "$MOUNT_USER:$MOUNT_USER" "$MOUNT_PATH"
        ok "SSD 디렉토리 구조 생성 완료 (80개 클래스)"
        df -h "$MOUNT_PATH"
    else
        warn "SSD 마운트 안 됨 – 디렉토리 생성 건너뜀"
    fi

    # ── 최종 확인 ──────────────────────────────────────────────────────────
    hdr "장치 연결 최종 확인"

    hailortcli fw-control identify 2>/dev/null && \
        ok "Hailo AI HAT+ 정상 감지" || \
        warn "Hailo 미감지 – 드라이버 및 PCIe 확인 필요"

    if command -v libcamera-hello &>/dev/null; then
        CAM=$(libcamera-hello --list-cameras 2>&1 || true)
        echo "$CAM" | grep -qi "imx519" && ok "Arducam UC-261 (IMX519) 감지됨"
        echo "$CAM" | grep -qi "imx500" && ok "RPi AI Camera (IMX500) 감지됨"
        echo "$CAM" | grep -qiE "imx519|imx500" || warn "CSI 카메라 미감지 – 케이블 확인"
    fi

    # ── 서비스 정리 ────────────────────────────────────────────────────────
    systemctl disable pi5-yolo11-install.service 2>/dev/null || true
    rm -f /etc/systemd/system/pi5-yolo11-install.service
    systemctl daemon-reload
    rm -f "$STATE_FILE"

    # ── 완료 ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${G}${B}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${G}${B}║               ★ 모든 설치가 완료되었습니다! ★               ║${NC}"
    echo -e "${G}${B}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${B}가상환경 활성화:${NC}"
    echo -e "  ${C}source $VENV_DIR/bin/activate${NC}"
    echo ""
    echo -e "  ${B}카메라 확인:${NC}"
    echo -e "  ${C}python yolo11_detect.py --list-cameras${NC}"
    echo ""
    echo -e "  ${B}감지 실행:${NC}"
    echo -e "  ${C}python yolo11_detect.py --source picam --camera-type imx519${NC}"
    echo -e "  ${C}python yolo11_detect.py --source picam --camera-type imx500${NC}"
    echo ""
    echo -e "  ${B}데이터 관리:${NC}"
    echo -e "  ${C}python data_manager.py status${NC}"
    echo ""
    echo -e "  설치 로그: $LOG_FILE"
    echo ""
fi
