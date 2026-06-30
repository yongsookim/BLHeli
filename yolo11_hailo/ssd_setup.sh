#!/bin/bash
# ============================================================
#  Raspberry Pi 5 – NVMe SSD 설정 스크립트
#  장치: LAFVIN M.2 NVMe Adapter + M.2 NVMe SSD (2280)
#  마운트 경로: /media/kimyongsoo/PI5_SSD
#  실행: sudo bash ssd_setup.sh
# ============================================================

set -e

MOUNT_USER="kimyongsoo"
MOUNT_PATH="/media/$MOUNT_USER/PI5_SSD"
CONFIG_FILE="/boot/firmware/config.txt"
FSTAB_FILE="/etc/fstab"

# ── 색상 출력 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}  ✔ $1${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $1${NC}"; }
error() { echo -e "${RED}  ✘ $1${NC}"; }

# ── root 확인 ─────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "root 권한 필요: sudo bash ssd_setup.sh"
    exit 1
fi

echo "============================================================"
echo "  Raspberry Pi 5 NVMe SSD 설정"
echo "  마운트 경로: $MOUNT_PATH"
echo "============================================================"

# ════════════════════════════════════════════════════════════════
echo ""
echo "=== [1/6] PCIe NVMe 활성화 ==="
# ════════════════════════════════════════════════════════════════

# PCIe Gen3 활성화 (최대 속도)
if grep -q "^dtparam=pciex1_gen=3" "$CONFIG_FILE"; then
    info "PCIe Gen3 이미 활성화됨"
else
    echo "dtparam=pciex1_gen=3" >> "$CONFIG_FILE"
    info "PCIe Gen3 활성화 추가 → 재부팅 시 적용"
fi

# NVMe 드라이버 로드 확인
modprobe nvme 2>/dev/null || true
modprobe nvme_core 2>/dev/null || true

# ════════════════════════════════════════════════════════════════
echo ""
echo "=== [2/6] NVMe 장치 감지 ==="
# ════════════════════════════════════════════════════════════════

# NVMe 장치 탐색
NVME_DEV=""
for dev in /dev/nvme0n1 /dev/nvme1n1; do
    if [ -b "$dev" ]; then
        NVME_DEV="$dev"
        break
    fi
done

if [ -z "$NVME_DEV" ]; then
    warn "NVMe 장치를 찾을 수 없습니다."
    echo ""
    echo "  해결 방법:"
    echo "  1. SSD가 M.2 슬롯에 완전히 삽입되었는지 확인"
    echo "  2. LAFVIN 어댑터 FPC 케이블이 RPi5 PCIe 포트에 연결됐는지 확인"
    echo "  3. 재부팅 후 재시도: sudo reboot"
    echo "  4. 장치 확인: lspci | grep -i nvme"
    echo "             ls /dev/nvme*"
    exit 1
fi

# 장치 정보 출력
info "NVMe 장치 감지: $NVME_DEV"
nvme id-ctrl "$NVME_DEV" 2>/dev/null | grep -E "^mn|^sn|^fr" | head -5 || true
lsblk "$NVME_DEV" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════
echo ""
echo "=== [3/6] 파티션 및 포맷 확인 ==="
# ════════════════════════════════════════════════════════════════

NVME_PART="${NVME_DEV}p1"
NEEDS_FORMAT=false

if [ -b "$NVME_PART" ]; then
    FS_TYPE=$(blkid -o value -s TYPE "$NVME_PART" 2>/dev/null || echo "")
    if [ "$FS_TYPE" = "ext4" ] || [ "$FS_TYPE" = "exfat" ] || [ "$FS_TYPE" = "vfat" ]; then
        info "기존 파티션 감지: $NVME_PART ($FS_TYPE) – 포맷 건너뜀"
    else
        warn "파티션 있지만 파일시스템 불명: $FS_TYPE"
        NEEDS_FORMAT=true
    fi
else
    warn "파티션 없음 – 새로 생성합니다."
    NEEDS_FORMAT=true
fi

if [ "$NEEDS_FORMAT" = true ]; then
    echo ""
    echo -e "${YELLOW}  ★ 주의: $NVME_DEV 의 기존 데이터가 모두 삭제됩니다! ★${NC}"
    read -r -p "  계속하려면 'YES' 입력: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "  취소됨."
        exit 0
    fi

    echo "  GPT 파티션 테이블 생성 중..."
    parted -s "$NVME_DEV" mklabel gpt
    parted -s "$NVME_DEV" mkpart primary ext4 0% 100%
    sleep 1
    partprobe "$NVME_DEV"
    sleep 1

    echo "  ext4 포맷 중..."
    mkfs.ext4 -L "PI5_SSD" -F "$NVME_PART"
    info "포맷 완료: $NVME_PART (ext4, 레이블=PI5_SSD)"
fi

# ════════════════════════════════════════════════════════════════
echo ""
echo "=== [4/6] 마운트 설정 ==="
# ════════════════════════════════════════════════════════════════

# 마운트 포인트 생성
mkdir -p "$MOUNT_PATH"
chown "$MOUNT_USER:$MOUNT_USER" "$MOUNT_PATH" 2>/dev/null || true

# 이미 마운트됐으면 언마운트
if mountpoint -q "$MOUNT_PATH"; then
    umount "$MOUNT_PATH"
fi

# 즉시 마운트
mount "$NVME_PART" "$MOUNT_PATH"
chown -R "$MOUNT_USER:$MOUNT_USER" "$MOUNT_PATH"
info "마운트 완료: $NVME_PART → $MOUNT_PATH"

# ════════════════════════════════════════════════════════════════
echo ""
echo "=== [5/6] 부팅 자동 마운트 등록 (fstab) ==="
# ════════════════════════════════════════════════════════════════

UUID=$(blkid -o value -s UUID "$NVME_PART")
FSTAB_ENTRY="UUID=$UUID  $MOUNT_PATH  ext4  defaults,noatime,nofail  0  2"

if grep -q "$UUID" "$FSTAB_FILE"; then
    info "fstab 이미 등록됨 (UUID=$UUID)"
else
    echo "" >> "$FSTAB_FILE"
    echo "# NVMe SSD (LAFVIN M.2 Adapter) – PI5_SSD" >> "$FSTAB_FILE"
    echo "$FSTAB_ENTRY" >> "$FSTAB_FILE"
    info "fstab 등록 완료"
    echo "  $FSTAB_ENTRY"
fi

# ════════════════════════════════════════════════════════════════
echo ""
echo "=== [6/6] 데이터 디렉토리 구조 생성 ==="
# ════════════════════════════════════════════════════════════════

SSD="$MOUNT_PATH"

# ── 기본 디렉토리 ─────────────────────────────────────────────
mkdir -p \
    "$SSD/models" \
    "$SSD/detections" \
    "$SSD/videos" \
    "$SSD/images" \
    "$SSD/logs"

# ── 학습 데이터셋 (YOLO 형식) ──────────────────────────────────
for split in train val test; do
    mkdir -p "$SSD/dataset/images/$split"
    mkdir -p "$SSD/dataset/labels/$split"
done

# ── 분류별 가이드 사진 (COCO 80클래스) ────────────────────────
CLASSES=(
    "00_person"       "01_bicycle"      "02_car"           "03_motorcycle"
    "04_airplane"     "05_bus"          "06_train"         "07_truck"
    "08_boat"         "09_traffic_light" "10_fire_hydrant" "11_stop_sign"
    "12_parking_meter" "13_bench"       "14_bird"          "15_cat"
    "16_dog"          "17_horse"        "18_sheep"         "19_cow"
    "20_elephant"     "21_bear"         "22_zebra"         "23_giraffe"
    "24_backpack"     "25_umbrella"     "26_handbag"       "27_tie"
    "28_suitcase"     "29_frisbee"      "30_skis"          "31_snowboard"
    "32_sports_ball"  "33_kite"         "34_baseball_bat"  "35_baseball_glove"
    "36_skateboard"   "37_surfboard"    "38_tennis_racket" "39_bottle"
    "40_wine_glass"   "41_cup"          "42_fork"          "43_knife"
    "44_spoon"        "45_bowl"         "46_banana"        "47_apple"
    "48_sandwich"     "49_orange"       "50_broccoli"      "51_carrot"
    "52_hot_dog"      "53_pizza"        "54_donut"         "55_cake"
    "56_chair"        "57_couch"        "58_potted_plant"  "59_bed"
    "60_dining_table" "61_toilet"       "62_tv"            "63_laptop"
    "64_mouse"        "65_remote"       "66_keyboard"      "67_cell_phone"
    "68_microwave"    "69_oven"         "70_toaster"       "71_sink"
    "72_refrigerator" "73_book"         "74_clock"         "75_vase"
    "76_scissors"     "77_teddy_bear"   "78_hair_drier"    "79_toothbrush"
)

for cls in "${CLASSES[@]}"; do
    mkdir -p "$SSD/guide_photos/$cls"
done

# ── 권한 설정 ─────────────────────────────────────────────────
chown -R "$MOUNT_USER:$MOUNT_USER" "$SSD"
chmod -R 755 "$SSD"

info "디렉토리 구조 생성 완료"

# ── 용량 확인 ─────────────────────────────────────────────────
echo ""
df -h "$MOUNT_PATH"

# ── 구조 출력 ─────────────────────────────────────────────────
echo ""
echo "  생성된 디렉토리 구조:"
echo "  $SSD/"
echo "  ├── models/              ← HEF 모델 저장"
echo "  ├── detections/          ← 감지 결과 자동 저장"
echo "  ├── videos/              ← 입력 동영상"
echo "  ├── images/              ← 입력 이미지"
echo "  ├── logs/                ← 실행 로그"
echo "  ├── dataset/             ← YOLO 학습 데이터셋"
echo "  │   ├── images/{train,val,test}/"
echo "  │   └── labels/{train,val,test}/"
echo "  └── guide_photos/        ← 분류별 가이드 사진"
echo "      ├── 00_person/"
echo "      ├── 02_car/"
echo "      └── ... (80개 클래스)"

echo ""
echo "============================================================"
echo -e "${GREEN}  SSD 설정 완료!${NC}"
echo ""
echo "  NVMe 속도 확인:"
echo "    sudo hdparm -tT $NVME_PART"
echo ""
echo "  다음 단계:"
echo "    bash setup.sh       ← YOLO11 환경 설치"
echo "    python data_manager.py --help  ← 데이터 관리"
echo "============================================================"
