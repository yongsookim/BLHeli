# YOLO11 Object Detection – Raspberry Pi 5 + Hailo AI HAT+

## 하드웨어 요구사항

| 항목 | 사양 |
|------|------|
| SBC | Raspberry Pi 5 (4GB / 8GB) |
| AI 가속기 | Hailo AI HAT+ (Hailo-8L, 13 TOPS) |
| 카메라 | Pi Camera Module 3 또는 USB 웹캠 |
| 저장장치 | SSD (`/media/kimyongsoo/PI5_SSD`) |
| OS | Raspberry Pi OS Bookworm (64-bit) |

---

## 빠른 시작

### 1. 환경 설치

```bash
bash setup.sh
source ~/hailo_env/bin/activate
```

### 2. 실행

```bash
# Pi Camera 실시간 감지
python yolo11_detect.py --source picam

# USB 웹캠 (인덱스 0)
python yolo11_detect.py --source 0

# SSD의 동영상 파일 감지 후 저장
python yolo11_detect.py \
    --source /media/kimyongsoo/PI5_SSD/videos/input.mp4 \
    --save-video

# 이미지 파일 감지
python yolo11_detect.py \
    --source /media/kimyongsoo/PI5_SSD/images/photo.jpg

# 커스텀 모델·임계값
python yolo11_detect.py \
    --source picam \
    --model /media/kimyongsoo/PI5_SSD/models/yolo11s.hef \
    --conf 0.4 --iou 0.5

# 헤드리스 모드 (화면 없이 저장만)
python yolo11_detect.py \
    --source picam \
    --save-video \
    --no-display
```

---

## 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--source` | `picam` | 입력 소스 (picam / 0~2 / 파일경로) |
| `--model` | `PI5_SSD/models/yolo11n.hef` | Hailo HEF 모델 경로 |
| `--conf` | `0.35` | 객체 신뢰도 임계값 |
| `--iou` | `0.45` | NMS IoU 임계값 |
| `--width` | `1280` | 출력 너비 (픽셀) |
| `--height` | `720` | 출력 높이 (픽셀) |
| `--save-video` | `False` | 감지 영상을 SSD에 저장 |
| `--output-dir` | `PI5_SSD/detections` | 결과 저장 경로 |
| `--no-display` | `False` | 화면 출력 비활성화 |

---

## 단축키 (디스플레이 모드)

| 키 | 기능 |
|----|------|
| `q` / `ESC` | 종료 |
| `s` | 현재 프레임 스냅샷 저장 |

---

## SSD 디렉토리 구조

```
/media/kimyongsoo/PI5_SSD/
├── models/
│   ├── yolo11n.hef    ← 경량 (가장 빠름)
│   ├── yolo11s.hef    ← 균형
│   └── yolo11m.hef    ← 고정밀
├── detections/        ← 감지 결과 저장
├── videos/            ← 입력 동영상
└── images/            ← 입력 이미지
```

---

## Hailo HEF 모델 구하기

Hailo Model Zoo 사전 컴파일 모델 (Hailo-8L 전용):

```bash
# yolo11n (nano, 가장 빠름)
wget -O /media/kimyongsoo/PI5_SSD/models/yolo11n.hef \
  https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8l/yolov11n.hef

# yolo11s (small)
wget -O /media/kimyongsoo/PI5_SSD/models/yolo11s.hef \
  https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8l/yolov11s.hef
```

직접 컴파일하려면 [Hailo Dataflow Compiler](https://hailo.ai/developer-zone/sw-downloads/) 사용.

---

## Hailo 드라이버 설치

```bash
# 1. PCIe Gen3 활성화 (config.txt)
echo "dtparam=pciex1_gen=3" | sudo tee -a /boot/firmware/config.txt

# 2. HailoRT 드라이버 설치
sudo apt install hailort

# 3. 재부팅
sudo reboot

# 4. 장치 확인
hailortcli fw-control identify
```

---

## 성능 참고

| 모델 | 입력 | mAP50 | Hailo-8L FPS (추정) |
|------|------|-------|----------------------|
| yolo11n | 640×640 | 39.5 | ~60 fps |
| yolo11s | 640×640 | 47.0 | ~45 fps |
| yolo11m | 640×640 | 51.5 | ~25 fps |
