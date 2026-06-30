#!/usr/bin/env python3
"""
분류별 가이드 사진 데이터 관리 스크립트
SSD 경로: /media/kimyongsoo/PI5_SSD
"""

import argparse
import shutil
import json
import datetime
from pathlib import Path

SSD_BASE    = Path("/media/kimyongsoo/PI5_SSD")
GUIDE_DIR   = SSD_BASE / "guide_photos"
DATASET_DIR = SSD_BASE / "dataset"
LOG_DIR     = SSD_BASE / "logs"

COCO_CLASSES = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic_light", "fire_hydrant", "stop_sign",
    "parking_meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
    "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag",
    "tie", "suitcase", "frisbee", "skis", "snowboard", "sports_ball", "kite",
    "baseball_bat", "baseball_glove", "skateboard", "surfboard",
    "tennis_racket", "bottle", "wine_glass", "cup", "fork", "knife", "spoon",
    "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
    "hot_dog", "pizza", "donut", "cake", "chair", "couch", "potted_plant",
    "bed", "dining_table", "toilet", "tv", "laptop", "mouse", "remote",
    "keyboard", "cell_phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy_bear",
    "hair_drier", "toothbrush",
]


def class_dir_name(idx: int, name: str) -> str:
    return f"{idx:02d}_{name}"


# ══════════════════════════════════════════════════════════════════════════════
#  명령 함수
# ══════════════════════════════════════════════════════════════════════════════

def cmd_status(_args):
    """SSD 마운트 상태 및 디렉토리 현황 출력."""
    if not SSD_BASE.exists():
        print(f"[오류] SSD 마운트 안 됨: {SSD_BASE}")
        print("  sudo bash ssd_setup.sh 을 먼저 실행하세요.")
        return

    total, used, free = shutil.disk_usage(SSD_BASE)
    print(f"\n SSD: {SSD_BASE}")
    print(f"  용량: {total/1e9:.1f} GB  사용: {used/1e9:.1f} GB  여유: {free/1e9:.1f} GB")
    print(f"  사용률: {used/total*100:.1f}%\n")

    if not GUIDE_DIR.exists():
        print("  guide_photos 디렉토리 없음 – ssd_setup.sh 재실행 필요")
        return

    print("  분류별 가이드 사진 현황:")
    print(f"  {'클래스':<30} {'사진 수':>7}")
    print("  " + "-" * 40)
    total_photos = 0
    for idx, name in enumerate(COCO_CLASSES):
        d = GUIDE_DIR / class_dir_name(idx, name)
        if d.exists():
            count = len(list(d.glob("*.jpg")) + list(d.glob("*.png")) + list(d.glob("*.jpeg")))
            if count > 0:
                print(f"  {class_dir_name(idx, name):<30} {count:>7}장")
            total_photos += count
    print("  " + "-" * 40)
    print(f"  {'합계':<30} {total_photos:>7}장\n")


def cmd_add(args):
    """이미지 파일을 지정 클래스 폴더에 추가."""
    cls_name = args.class_name.lower().replace(" ", "_")
    matched = [(i, n) for i, n in enumerate(COCO_CLASSES) if n == cls_name]
    if not matched:
        # 부분 매칭 시도
        matched = [(i, n) for i, n in enumerate(COCO_CLASSES) if cls_name in n]
    if not matched:
        print(f"[오류] 클래스 '{args.class_name}' 없음.")
        print("  사용 가능한 클래스: python data_manager.py --list-classes")
        return

    idx, name = matched[0]
    dest_dir = GUIDE_DIR / class_dir_name(idx, name)
    dest_dir.mkdir(parents=True, exist_ok=True)

    added = 0
    for src in args.files:
        src_path = Path(src)
        if not src_path.exists():
            print(f"  [건너뜀] 파일 없음: {src}")
            continue
        if src_path.suffix.lower() not in (".jpg", ".jpeg", ".png", ".bmp", ".webp"):
            print(f"  [건너뜀] 미지원 형식: {src}")
            continue
        ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S%f")
        dest = dest_dir / f"{name}_{ts}{src_path.suffix.lower()}"
        shutil.copy2(src_path, dest)
        print(f"  [추가] {src_path.name} → {dest.relative_to(SSD_BASE)}")
        added += 1

    print(f"\n  {added}개 파일 추가 완료 → {class_dir_name(idx, name)}/")


def cmd_capture(args):
    """Pi Camera로 현재 프레임을 지정 클래스 폴더에 저장."""
    try:
        from picamera2 import Picamera2
    except ImportError:
        print("[오류] picamera2 미설치")
        return

    cls_name = args.class_name.lower().replace(" ", "_")
    matched = [(i, n) for i, n in enumerate(COCO_CLASSES) if cls_name in n]
    if not matched:
        print(f"[오류] 클래스 '{args.class_name}' 없음.")
        return

    idx, name = matched[0]
    dest_dir = GUIDE_DIR / class_dir_name(idx, name)
    dest_dir.mkdir(parents=True, exist_ok=True)

    cam = Picamera2(args.camera_id)
    config = cam.create_still_configuration(
        main={"size": (args.width, args.height), "format": "BGR888"}
    )
    cam.configure(config)
    cam.start()

    import time
    import cv2
    time.sleep(1.0)

    saved = 0
    print(f"  클래스: {class_dir_name(idx, name)}  촬영 매수: {args.count}")
    print("  촬영 중... (각 촬영 후 미리보기 창에서 아무 키나 누르세요)")

    for i in range(args.count):
        frame = cam.capture_array()
        ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S%f")
        dest = dest_dir / f"{name}_{ts}.jpg"

        cv2.imshow(f"캡처 [{i+1}/{args.count}] – {name}", frame[:, :, ::-1])
        cv2.waitKey(args.interval * 1000 if args.interval > 0 else 0)
        cv2.imwrite(str(dest), frame[:, :, ::-1])
        print(f"  [{i+1}/{args.count}] 저장: {dest.name}")
        saved += 1

    cam.stop()
    cv2.destroyAllWindows()
    print(f"\n  {saved}장 저장 완료 → {class_dir_name(idx, name)}/")


def cmd_list_classes(_args):
    """사용 가능한 클래스 목록 출력."""
    print("\n  COCO 80클래스 목록:")
    print(f"  {'번호':<6} {'클래스':<25} {'가이드 사진 수':>12}")
    print("  " + "-" * 46)
    for idx, name in enumerate(COCO_CLASSES):
        d = GUIDE_DIR / class_dir_name(idx, name)
        count = 0
        if d.exists():
            count = len(list(d.glob("*.jpg")) + list(d.glob("*.png")))
        bar = "█" * min(count // 5, 10)
        print(f"  {idx:<6} {name:<25} {count:>6}장  {bar}")
    print()


def cmd_export(args):
    """가이드 사진을 YOLO 학습용 dataset/ 형식으로 내보내기."""
    import random

    split_ratio = {"train": 0.7, "val": 0.2, "test": 0.1}
    exported = {"train": 0, "val": 0, "test": 0}

    print(f"\n  YOLO 데이터셋으로 내보내기: {DATASET_DIR}")

    for idx, name in enumerate(COCO_CLASSES):
        src_dir = GUIDE_DIR / class_dir_name(idx, name)
        if not src_dir.exists():
            continue
        imgs = (list(src_dir.glob("*.jpg")) +
                list(src_dir.glob("*.jpeg")) +
                list(src_dir.glob("*.png")))
        if not imgs:
            continue

        random.shuffle(imgs)
        n = len(imgs)
        n_train = int(n * split_ratio["train"])
        n_val   = int(n * split_ratio["val"])

        splits = (
            ("train", imgs[:n_train]),
            ("val",   imgs[n_train:n_train + n_val]),
            ("test",  imgs[n_train + n_val:]),
        )

        for split_name, split_imgs in splits:
            img_out_dir = DATASET_DIR / "images" / split_name
            lbl_out_dir = DATASET_DIR / "labels" / split_name
            img_out_dir.mkdir(parents=True, exist_ok=True)
            lbl_out_dir.mkdir(parents=True, exist_ok=True)

            for src in split_imgs:
                dst_img = img_out_dir / src.name
                shutil.copy2(src, dst_img)

                # 전체 이미지를 해당 클래스로 라벨링 (cx=0.5, cy=0.5, w=1.0, h=1.0)
                dst_lbl = lbl_out_dir / (src.stem + ".txt")
                dst_lbl.write_text(f"{idx} 0.5 0.5 1.0 1.0\n")
                exported[split_name] += 1

    # dataset.yaml 생성
    yaml_path = DATASET_DIR / "dataset.yaml"
    yaml_content = f"""# YOLO11 Dataset Configuration
path: {DATASET_DIR}
train: images/train
val:   images/val
test:  images/test

nc: {len(COCO_CLASSES)}
names: {COCO_CLASSES}
"""
    yaml_path.write_text(yaml_content)

    print(f"  train: {exported['train']}장")
    print(f"  val:   {exported['val']}장")
    print(f"  test:  {exported['test']}장")
    print(f"  dataset.yaml → {yaml_path}")


def cmd_report(_args):
    """SSD 상태 JSON 리포트 저장."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    report = {
        "timestamp": datetime.datetime.now().isoformat(),
        "ssd_path": str(SSD_BASE),
        "classes": {}
    }
    for idx, name in enumerate(COCO_CLASSES):
        d = GUIDE_DIR / class_dir_name(idx, name)
        count = 0
        size_mb = 0
        if d.exists():
            files = list(d.glob("*.jpg")) + list(d.glob("*.png")) + list(d.glob("*.jpeg"))
            count = len(files)
            size_mb = round(sum(f.stat().st_size for f in files) / 1e6, 2)
        report["classes"][class_dir_name(idx, name)] = {
            "count": count, "size_mb": size_mb
        }

    out = LOG_DIR / f"report_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"  리포트 저장: {out}")


# ══════════════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="YOLO11 분류별 가이드 사진 데이터 관리",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  # SSD 현황 확인
  python data_manager.py status

  # 클래스 목록 확인
  python data_manager.py list-classes

  # 이미지 파일 추가
  python data_manager.py add --class car photo1.jpg photo2.jpg

  # 카메라로 직접 촬영하여 저장
  python data_manager.py capture --class person --count 10

  # YOLO 학습 데이터셋으로 내보내기
  python data_manager.py export

  # JSON 리포트 저장
  python data_manager.py report
""",
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("status",       help="SSD 현황 및 분류별 사진 수 출력")
    sub.add_parser("list-classes", help="COCO 80클래스 목록 출력")
    sub.add_parser("report",       help="JSON 리포트 저장")
    sub.add_parser("export",       help="가이드 사진 → YOLO 데이터셋 내보내기")

    p_add = sub.add_parser("add", help="이미지 파일을 클래스 폴더에 추가")
    p_add.add_argument("--class", dest="class_name", required=True, help="클래스명 (예: car, person)")
    p_add.add_argument("files", nargs="+", help="추가할 이미지 파일 경로")

    p_cap = sub.add_parser("capture", help="카메라로 촬영하여 클래스 폴더에 저장")
    p_cap.add_argument("--class",     dest="class_name", required=True, help="클래스명")
    p_cap.add_argument("--count",     type=int, default=5,   help="촬영 매수 (기본: 5)")
    p_cap.add_argument("--interval",  type=int, default=0,   help="자동 촬영 간격(초), 0=수동")
    p_cap.add_argument("--camera-id", type=int, default=0,   help="카메라 포트 번호 (기본: 0)")
    p_cap.add_argument("--width",     type=int, default=1920, help="촬영 너비 (기본: 1920)")
    p_cap.add_argument("--height",    type=int, default=1080, help="촬영 높이 (기본: 1080)")

    args = parser.parse_args()

    dispatch = {
        "status":       cmd_status,
        "list-classes": cmd_list_classes,
        "add":          cmd_add,
        "capture":      cmd_capture,
        "export":       cmd_export,
        "report":       cmd_report,
    }

    if args.command in dispatch:
        dispatch[args.command](args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
