# YOLO11 Object Detection – Raspberry Pi 5 + Hailo AI HAT+

## 하드웨어 구성

| 항목 | 사양 |
|------|------|
| SBC | Raspberry Pi 5 (4GB / 8GB) |
| AI 가속기 | Hailo AI HAT+ (Hailo-8L, 13 TOPS) |
| 카메라 1 | Arducam UC-261 (IMX519, 16MP, 자동초점) |
| 카메라 2 | Raspberry Pi AI Camera (IMX500, 12MP) |
| SSD 어댑터 | LAFVIN M.2 NVMe Adapter for RPI 5 (PCIe 3.0 x1) |
| SSD | M.2 NVMe SSD 2280 |
| OS | Raspberry Pi OS Bookworm (64-bit) |

---

## 파일 구성

| 파일 | 설명 |
|------|------|
| `install.sh` | **통합 설치** – 이것 하나만 실행하면 전체 설치 완료 |
| `ssd_setup.sh` | NVMe SSD 파티션·마운트·디렉토리 개별 설정 |
| `setup.sh` | YOLO11 Python 환경·카메라 드라이버·모델 개별 설치 |
| `yolo11_detect.py` | YOLO11 객체 감지 메인 스크립트 |
| `data_manager.py` | 분류별 가이드 사진 데이터 관리 도구 |
| `requirements.txt` | Python 패키지 목록 |

---

## 빠른 시작 (통합 설치)

### 1. 파일 다운로드

```bash
git clone https://github.com/yongsookim/BLHeli.git
cd BLHeli
git checkout claude/yolo11-raspberry-pi-hailo-vbszde
cd yolo11_hailo
```

### 2. 통합 설치 (한 번 실행으로 전체 완료)

```bash
sudo bash install.sh
```

**자동 진행 흐름:**
```
1단계: PCIe Gen3 활성화 → NVMe SSD 설정 → 카메라 드라이버 설치
         → 재부팅 (자동)
2단계: Python 환경 → 패키지 설치 → HEF 모델 다운로드 → SSD 디렉토리 생성
         → 설치 완료 ★
```

> 총 소요 시간: 약 10~15분 (재부팅 포함)

### 3. 감지 실행

```bash
source ~/hailo_env/bin/activate
cd yolo11_hailo

# 카메라 연결 확인
python yolo11_detect.py --list-cameras

# Arducam UC-261 (IMX519) 실시간 감지
python yolo11_detect.py --source picam --camera-type imx519

# Raspberry Pi AI Camera (IMX500) 실시간 감지
python yolo11_detect.py --source picam --camera-type imx500
```

---

## yolo11_detect.py 전체 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--source` | `picam` | 입력 소스: picam / 0(USB) / 파일경로 |
| `--camera-type` | `auto` | 카메라 모델: `imx519` / `imx500` / `auto` |
| `--camera-id` | `0` | CSI 포트 번호 (0 또는 1) |
| `--model` | `PI5_SSD/models/yolo11n.hef` | Hailo HEF 모델 경로 |
| `--conf` | `0.35` | 객체 신뢰도 임계값 |
| `--iou` | `0.45` | NMS IoU 임계값 |
| `--width` | `1280` | 출력 너비 (픽셀) |
| `--height` | `720` | 출력 높이 (픽셀) |
| `--save-video` | `False` | 감지 영상을 SSD에 저장 |
| `--output-dir` | `PI5_SSD/detections` | 결과 저장 경로 |
| `--no-display` | `False` | 화면 출력 비활성화 (헤드리스) |
| `--list-cameras` | – | 연결된 CSI 카메라 목록 출력 후 종료 |

### 실행 예시

```bash
# Arducam UC-261 (자동초점) + 영상 저장
python yolo11_detect.py --source picam --camera-type imx519 --save-video

# CSI 포트 1번 카메라 사용
python yolo11_detect.py --source picam --camera-type imx500 --camera-id 1

# USB 웹캠
python yolo11_detect.py --source 0

# SSD 동영상 파일 감지
python yolo11_detect.py \
    --source /media/kimyongsoo/PI5_SSD/videos/input.mp4 \
    --save-video

# 고정밀 모델 + 높은 신뢰도
python yolo11_detect.py \
    --source picam --camera-type imx519 \
    --model /media/kimyongsoo/PI5_SSD/models/yolo11s.hef \
    --conf 0.5 --iou 0.5

# 헤드리스 모드 (화면 없이 저장만)
python yolo11_detect.py \
    --source picam --save-video --no-display
```

### 단축키 (디스플레이 모드)

| 키 | 기능 |
|----|------|
| `q` / `ESC` | 종료 |
| `s` | 현재 프레임 스냅샷 저장 |

---

## 카메라 사양

### Arducam UC-261 (IMX519)

| 항목 | 사양 |
|------|------|
| 센서 | Sony IMX519 |
| 해상도 | 16MP (4656×3496) |
| 인터페이스 | CSI-2 (MIPI) |
| 초점 | 연속 자동초점 (AF) |
| 연결 | RPi5 CAM 포트 |

### Raspberry Pi AI Camera (IMX500)

| 항목 | 사양 |
|------|------|
| 센서 | Sony IMX500 |
| 해상도 | 12MP (4056×3040) |
| 인터페이스 | CSI-2 (MIPI) |
| 초점 | 고정초점 |
| 특징 | 온칩 AI (Hailo 사용 시 불필요) |

---

## SSD 디렉토리 구조

```
/media/kimyongsoo/PI5_SSD/
├── models/
│   ├── yolo11n.hef        ← 경량 (~60 fps)
│   └── yolo11s.hef        ← 균형 (~45 fps)
├── detections/            ← 감지 결과 자동 저장
├── videos/                ← 입력 동영상
├── images/                ← 입력 이미지
├── logs/                  ← 실행 로그
├── dataset/               ← YOLO 학습 데이터셋
│   ├── images/{train, val, test}/
│   └── labels/{train, val, test}/
└── guide_photos/          ← 분류별 가이드 사진 (80클래스)
    ├── 00_person/
    ├── 01_bicycle/
    ├── 02_car/
    └── ... (79_toothbrush 까지)
```

---

## data_manager.py 사용법

```bash
source ~/hailo_env/bin/activate

# SSD 현황 및 클래스별 사진 수 확인
python data_manager.py status

# COCO 80클래스 목록 확인
python data_manager.py list-classes

# 이미지 파일을 클래스 폴더에 추가
python data_manager.py add --class car photo1.jpg photo2.jpg

# 카메라로 직접 촬영하여 저장 (10장)
python data_manager.py capture --class person --count 10

# 가이드 사진 → YOLO 학습 데이터셋으로 변환 (7:2:1 분할)
python data_manager.py export

# JSON 리포트 저장
python data_manager.py report
```

---

## Hailo 드라이버 설치 (수동)

`install.sh` 실행 전 Hailo 드라이버를 별도 설치해야 합니다:

```bash
# 1. PCIe Gen3 활성화
echo "dtparam=pciex1_gen=3" | sudo tee -a /boot/firmware/config.txt

# 2. HailoRT 설치
sudo apt install hailort

# 3. 재부팅
sudo reboot

# 4. 장치 확인
hailortcli fw-control identify
```

---

## 성능 참고 (Hailo-8L 기준)

| 모델 | 입력 | mAP50 | 추정 FPS |
|------|------|-------|----------|
| yolo11n | 640×640 | 39.5 | ~60 fps |
| yolo11s | 640×640 | 47.0 | ~45 fps |
| yolo11m | 640×640 | 51.5 | ~25 fps |

---

## 문제 해결

| 증상 | 해결 방법 |
|------|-----------|
| NVMe 장치 미감지 | `lspci \| grep -i nvme` 확인 후 재부팅 |
| 카메라 미감지 | `libcamera-hello --list-cameras` 확인 |
| IMX519 자동초점 안 됨 | `sudo apt install python3-picamera2` 최신 버전 확인 |
| hailo_platform 오류 | `hailortcli fw-control identify` 로 드라이버 확인 |
| SSD 마운트 실패 | `sudo bash ssd_setup.sh` 재실행 |
