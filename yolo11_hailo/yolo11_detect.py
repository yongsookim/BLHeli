#!/usr/bin/env python3
"""
YOLO11 Object Detection - Raspberry Pi 5 + Hailo AI HAT+

지원 입력: Pi Camera, USB 웹캠, 비디오 파일, 이미지 파일
SSD 경로: /media/kimyongsoo/PI5_SSD
"""

import argparse
import os
import sys
import time
import datetime
import threading
import queue
from pathlib import Path

import cv2
import numpy as np

# ── Hailo SDK ──────────────────────────────────────────────────────────────────
try:
    from hailo_platform import (
        VDevice,
        HEF,
        ConfigureParams,
        InputVStreamParams,
        OutputVStreamParams,
        FormatType,
        HailoStreamInterface,
        InferVStreams,
        HailoSchedulingAlgorithm,
    )
    HAILO_AVAILABLE = True
except ImportError:
    print("[경고] hailo_platform 미설치 – 데모 모드(CPU)로 실행합니다.")
    HAILO_AVAILABLE = False

# ── picamera2 (선택) ───────────────────────────────────────────────────────────
try:
    from picamera2 import Picamera2
    PICAMERA_AVAILABLE = True
except ImportError:
    PICAMERA_AVAILABLE = False

# ──────────────────────────────────────────────────────────────────────────────
SSD_BASE = Path("/media/kimyongsoo/PI5_SSD")
DEFAULT_MODEL = SSD_BASE / "models" / "yolo11n.hef"
DEFAULT_OUTPUT_DIR = SSD_BASE / "detections"

COCO_CLASSES = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
    "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag",
    "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite",
    "baseball bat", "baseball glove", "skateboard", "surfboard",
    "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon",
    "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
    "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant",
    "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote",
    "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
    "hair drier", "toothbrush",
]

np.random.seed(42)
CLASS_COLORS = np.random.randint(50, 255, (len(COCO_CLASSES), 3), dtype=np.uint8)


# ══════════════════════════════════════════════════════════════════════════════
#  전처리 / 후처리
# ══════════════════════════════════════════════════════════════════════════════

def preprocess(frame: np.ndarray, input_h: int, input_w: int):
    """BGR → RGB, letterbox 리사이즈, float32 정규화."""
    img_h, img_w = frame.shape[:2]
    scale = min(input_w / img_w, input_h / img_h)
    new_w, new_h = int(img_w * scale), int(img_h * scale)

    resized = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
    padded = np.full((input_h, input_w, 3), 114, dtype=np.uint8)
    pad_top = (input_h - new_h) // 2
    pad_left = (input_w - new_w) // 2
    padded[pad_top:pad_top + new_h, pad_left:pad_left + new_w] = resized

    img = padded[:, :, ::-1].astype(np.float32) / 255.0  # BGR→RGB, [0,1]
    return img, scale, pad_left, pad_top


def decode_hailo_output(raw_outputs: dict, conf_thresh: float, nms_thresh: float,
                        orig_h: int, orig_w: int,
                        scale: float, pad_left: int, pad_top: int,
                        input_h: int, input_w: int):
    """
    Hailo HEF 출력 디코딩.
    Hailo Model Zoo YOLO11 HEF는 온디바이스 NMS 결과를
    (num_detections, [y_min, x_min, y_max, x_max, score, class_id]) 형태로 반환합니다.
    """
    boxes, scores, class_ids = [], [], []

    for name, tensor in raw_outputs.items():
        tensor = np.squeeze(tensor)
        if tensor.ndim == 0:
            continue

        # ── 형태 1: NMS 완료 [N, 6]  (y1,x1,y2,x2,score,cls) ──────────────
        if tensor.ndim == 2 and tensor.shape[-1] == 6:
            for det in tensor:
                y1, x1, y2, x2, score, cls_id = det
                if score < conf_thresh:
                    continue
                # 패딩·스케일 역산 → 원본 좌표
                x1 = (x1 * input_w - pad_left) / scale
                y1 = (y1 * input_h - pad_top) / scale
                x2 = (x2 * input_w - pad_left) / scale
                y2 = (y2 * input_h - pad_top) / scale
                boxes.append([
                    max(0, int(x1)), max(0, int(y1)),
                    min(orig_w, int(x2)), min(orig_h, int(y2)),
                ])
                scores.append(float(score))
                class_ids.append(int(cls_id))

        # ── 형태 2: 앵커 텐서 [H, W, A*(5+C)]  (원시 출력) ─────────────────
        elif tensor.ndim == 3:
            h, w, ch = tensor.shape
            num_anchors = ch // (5 + len(COCO_CLASSES))
            if num_anchors == 0:
                continue
            for row in range(h):
                for col in range(w):
                    for a in range(num_anchors):
                        offset = a * (5 + len(COCO_CLASSES))
                        obj = tensor[row, col, offset + 4]
                        if obj < conf_thresh:
                            continue
                        cls_scores = tensor[row, col, offset + 5:offset + 5 + len(COCO_CLASSES)]
                        cls_id = int(np.argmax(cls_scores))
                        score = float(obj * cls_scores[cls_id])
                        if score < conf_thresh:
                            continue
                        cx = (col + tensor[row, col, offset]) / w
                        cy = (row + tensor[row, col, offset + 1]) / h
                        bw = tensor[row, col, offset + 2]
                        bh = tensor[row, col, offset + 3]
                        x1 = (cx - bw / 2) * input_w
                        y1 = (cy - bh / 2) * input_h
                        x2 = (cx + bw / 2) * input_w
                        y2 = (cy + bh / 2) * input_h
                        x1 = (x1 - pad_left) / scale
                        y1 = (y1 - pad_top) / scale
                        x2 = (x2 - pad_left) / scale
                        y2 = (y2 - pad_top) / scale
                        boxes.append([
                            max(0, int(x1)), max(0, int(y1)),
                            min(orig_w, int(x2)), min(orig_h, int(y2)),
                        ])
                        scores.append(score)
                        class_ids.append(cls_id)

    if not boxes:
        return [], [], []

    # NMS (온디바이스 NMS가 없는 경우 대비)
    indices = cv2.dnn.NMSBoxes(
        [[b[0], b[1], b[2] - b[0], b[3] - b[1]] for b in boxes],
        scores, conf_thresh, nms_thresh,
    )
    if len(indices) == 0:
        return [], [], []
    indices = indices.flatten()
    return (
        [boxes[i] for i in indices],
        [scores[i] for i in indices],
        [class_ids[i] for i in indices],
    )


# ══════════════════════════════════════════════════════════════════════════════
#  그리기
# ══════════════════════════════════════════════════════════════════════════════

def draw_detections(frame: np.ndarray, boxes, scores, class_ids,
                    fps: float = 0.0) -> np.ndarray:
    for (x1, y1, x2, y2), score, cls_id in zip(boxes, scores, class_ids):
        color = CLASS_COLORS[cls_id % len(CLASS_COLORS)].tolist()
        label = f"{COCO_CLASSES[cls_id] if cls_id < len(COCO_CLASSES) else cls_id}: {score:.2f}"
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.55, 1)
        bg_y1 = max(y1 - th - 6, 0)
        cv2.rectangle(frame, (x1, bg_y1), (x1 + tw + 4, y1), color, -1)
        cv2.putText(frame, label, (x1 + 2, y1 - 3),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)

    if fps > 0:
        cv2.putText(frame, f"FPS: {fps:.1f}", (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 0), 2, cv2.LINE_AA)
    cv2.putText(frame, datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                (10, frame.shape[0] - 10),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1, cv2.LINE_AA)
    return frame


# ══════════════════════════════════════════════════════════════════════════════
#  Hailo 추론 클래스
# ══════════════════════════════════════════════════════════════════════════════

class HailoYOLO11:
    def __init__(self, hef_path: str):
        self.hef_path = hef_path
        self._target = None
        self._network_group = None
        self._input_vstream_params = None
        self._output_vstream_params = None
        self._input_name = None
        self.input_h = 640
        self.input_w = 640
        self._setup()

    def _setup(self):
        if not HAILO_AVAILABLE:
            print("[데모] Hailo SDK 없음 – CPU 추론 불가.")
            return
        if not os.path.exists(self.hef_path):
            raise FileNotFoundError(f"HEF 모델 없음: {self.hef_path}\n"
                                    "setup.sh 를 실행해 모델을 다운로드하세요.")

        self._target = VDevice()
        hef = HEF(self.hef_path)

        configure_params = ConfigureParams.create_from_hef(
            hef, interface=HailoStreamInterface.PCIe
        )
        network_groups = self._target.configure(hef, configure_params)
        self._network_group = network_groups[0]
        self._network_group_params = self._network_group.create_params()

        self._input_vstream_params = InputVStreamParams.make_from_network_group(
            self._network_group, quantized=False, format_type=FormatType.FLOAT32
        )
        self._output_vstream_params = OutputVStreamParams.make_from_network_group(
            self._network_group, quantized=False, format_type=FormatType.FLOAT32
        )

        input_info = hef.get_input_vstream_infos()[0]
        self._input_name = input_info.name
        shape = input_info.shape          # (H, W, C)
        self.input_h, self.input_w = shape[0], shape[1]
        print(f"[Hailo] 모델 로드 완료 | 입력: {self._input_name} {shape}")

    def infer(self, frame: np.ndarray):
        """단일 프레임 추론 → (raw_outputs, scale, pad_left, pad_top)"""
        img, scale, pad_left, pad_top = preprocess(frame, self.input_h, self.input_w)
        input_data = {self._input_name: np.expand_dims(img, axis=0)}

        with InferVStreams(
            self._network_group,
            self._input_vstream_params,
            self._output_vstream_params,
        ) as pipeline:
            with self._network_group.activate(self._network_group_params):
                raw = pipeline.infer(input_data)
        return raw, scale, pad_left, pad_top

    def __del__(self):
        if self._target is not None:
            try:
                self._target.release()
            except Exception:
                pass


# ══════════════════════════════════════════════════════════════════════════════
#  카메라 소스
# ══════════════════════════════════════════════════════════════════════════════

class CameraSource:
    """Pi Camera 또는 USB 웹캠 통합 래퍼."""

    def __init__(self, source, width=1280, height=720):
        self._use_picam = False
        self._cap = None
        self._picam = None
        self.width = width
        self.height = height

        if source == "picam" and PICAMERA_AVAILABLE:
            self._use_picam = True
            self._picam = Picamera2()
            config = self._picam.create_preview_configuration(
                main={"size": (width, height), "format": "BGR888"}
            )
            self._picam.configure(config)
            self._picam.start()
            time.sleep(0.5)
            print(f"[카메라] Pi Camera 시작 ({width}×{height})")
        else:
            idx = int(source) if str(source).isdigit() else source
            self._cap = cv2.VideoCapture(idx)
            if not self._cap.isOpened():
                raise RuntimeError(f"카메라 열기 실패: {source}")
            self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            print(f"[카메라] USB/V4L2 카메라 시작 (인덱스={source})")

    def read(self):
        if self._use_picam:
            return True, self._picam.capture_array()
        ret, frame = self._cap.read()
        return ret, frame

    def release(self):
        if self._use_picam and self._picam:
            self._picam.stop()
        if self._cap:
            self._cap.release()


# ══════════════════════════════════════════════════════════════════════════════
#  메인 파이프라인
# ══════════════════════════════════════════════════════════════════════════════

def run_detection(args):
    # ── 모델 로드 ──────────────────────────────────────────────────────────────
    if HAILO_AVAILABLE:
        model = HailoYOLO11(str(args.model))
    else:
        model = None
        print("[데모] 바운딩 박스 없이 영상만 표시합니다.")

    # ── 출력 디렉토리 ──────────────────────────────────────────────────────────
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # ── 입력 소스 결정 ─────────────────────────────────────────────────────────
    is_image = False
    is_camera = False
    video_path = None

    if args.source in ("picam", "0", "1", "2") or str(args.source).isdigit():
        is_camera = True
    elif Path(args.source).suffix.lower() in (".jpg", ".jpeg", ".png", ".bmp"):
        is_image = True
    else:
        video_path = args.source

    # ── 이미지 단건 처리 ───────────────────────────────────────────────────────
    if is_image:
        frame = cv2.imread(str(args.source))
        if frame is None:
            sys.exit(f"이미지를 열 수 없습니다: {args.source}")
        boxes, scores, class_ids = _infer_frame(model, frame, args)
        vis = draw_detections(frame.copy(), boxes, scores, class_ids)
        ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = out_dir / f"detect_{ts}.jpg"
        cv2.imwrite(str(out_path), vis)
        print(f"[저장] {out_path}  (감지: {len(boxes)}개)")
        if not args.no_display:
            cv2.imshow("YOLO11 Hailo", vis)
            cv2.waitKey(0)
        return

    # ── 비디오 / 카메라 처리 ───────────────────────────────────────────────────
    writer = None
    fps_target = 30.0

    if is_camera:
        src = CameraSource(args.source, args.width, args.height)
    else:
        src_path = Path(args.source)
        if not src_path.exists():
            sys.exit(f"파일 없음: {args.source}")
        src = cv2.VideoCapture(str(src_path))
        if not src.isOpened():
            sys.exit(f"비디오를 열 수 없습니다: {args.source}")
        fps_target = src.get(cv2.CAP_PROP_FPS) or 30.0

    if args.save_video:
        ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        out_video = out_dir / f"detect_{ts}.mp4"
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        writer = cv2.VideoWriter(
            str(out_video), fourcc, fps_target,
            (args.width, args.height)
        )
        print(f"[녹화] {out_video}")

    # ── FPS 계산 ───────────────────────────────────────────────────────────────
    fps = 0.0
    frame_count = 0
    t_start = time.perf_counter()

    print("시작합니다. 종료: q / ESC")
    try:
        while True:
            if is_camera:
                ret, frame = src.read()
            else:
                ret, frame = src.read()

            if not ret or frame is None:
                break

            # 리사이즈 (카메라 해상도 맞추기)
            if frame.shape[1] != args.width or frame.shape[0] != args.height:
                frame = cv2.resize(frame, (args.width, args.height))

            # 추론
            boxes, scores, class_ids = _infer_frame(model, frame, args)

            # 시각화
            frame_count += 1
            elapsed = time.perf_counter() - t_start
            if elapsed > 0:
                fps = frame_count / elapsed

            vis = draw_detections(frame.copy(), boxes, scores, class_ids, fps)

            if writer:
                writer.write(vis)

            if not args.no_display:
                cv2.imshow("YOLO11 - Hailo AI HAT+  (q/ESC: 종료)", vis)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    break
                if key == ord("s"):        # 스냅샷 저장
                    snap = out_dir / f"snap_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S%f')}.jpg"
                    cv2.imwrite(str(snap), vis)
                    print(f"[스냅샷] {snap}")

    finally:
        if is_camera:
            src.release()
        else:
            src.release()
        if writer:
            writer.release()
        cv2.destroyAllWindows()
        print(f"\n완료 | 총 {frame_count}프레임 | 평균 FPS: {fps:.1f}")


def _infer_frame(model, frame, args):
    """추론 후 boxes/scores/class_ids 반환."""
    if model is None:
        return [], [], []
    orig_h, orig_w = frame.shape[:2]
    raw_outputs, scale, pad_left, pad_top = model.infer(frame)
    return decode_hailo_output(
        raw_outputs, args.conf, args.iou,
        orig_h, orig_w, scale, pad_left, pad_top,
        model.input_h, model.input_w,
    )


# ══════════════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════════════

def parse_args():
    parser = argparse.ArgumentParser(
        description="YOLO11 Object Detection – Raspberry Pi 5 + Hailo AI HAT+",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  # Pi Camera로 실시간 감지
  python yolo11_detect.py --source picam

  # USB 웹캠 (인덱스 0)
  python yolo11_detect.py --source 0

  # SSD의 동영상 파일
  python yolo11_detect.py --source /media/kimyongsoo/PI5_SSD/videos/input.mp4 --save-video

  # 이미지 파일
  python yolo11_detect.py --source /media/kimyongsoo/PI5_SSD/images/photo.jpg

  # 커스텀 모델 / 임계값
  python yolo11_detect.py --source picam --model /media/kimyongsoo/PI5_SSD/models/yolo11s.hef --conf 0.4
""",
    )
    parser.add_argument("--source", default="picam",
                        help="입력 소스: picam / 0(USB) / 영상파일경로 / 이미지파일경로")
    parser.add_argument("--model", default=str(DEFAULT_MODEL),
                        help=f"HEF 모델 경로 (기본: {DEFAULT_MODEL})")
    parser.add_argument("--conf", type=float, default=0.35,
                        help="객체 신뢰도 임계값 (기본: 0.35)")
    parser.add_argument("--iou", type=float, default=0.45,
                        help="NMS IoU 임계값 (기본: 0.45)")
    parser.add_argument("--width", type=int, default=1280,
                        help="카메라/출력 너비 (기본: 1280)")
    parser.add_argument("--height", type=int, default=720,
                        help="카메라/출력 높이 (기본: 720)")
    parser.add_argument("--save-video", action="store_true",
                        help="감지 영상을 SSD에 저장")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR),
                        help=f"결과 저장 경로 (기본: {DEFAULT_OUTPUT_DIR})")
    parser.add_argument("--no-display", action="store_true",
                        help="화면 표시 없이 실행 (헤드리스 모드)")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    run_detection(args)
