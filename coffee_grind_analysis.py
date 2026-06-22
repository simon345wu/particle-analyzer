#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
咖啡粉粒徑分析程式 (Coffee Grind Particle Size Analyzer)
=========================================================

功能:
    讀取一張咖啡粉照片,自動偵測每一顆咖啡粉顆粒,計算其等效圓直徑
    (Equivalent Circular Diameter),並輸出:
        1. 標註後的影像(框出每顆被偵測到的顆粒)
        2. 粒徑分布直方圖 (Particle Size Distribution Histogram)
        3. 統計數據:平均值、中位數、D10 / D50 / D90、標準差等
        4. 每顆顆粒的詳細資料 CSV 檔

拍照建議(會直接影響分析準確度):
    【推薦做法:列印正方形校正框】
    1. 事先在 A4 白紙上列印一個已知邊長的正方形外框(預設假設 15cm x 15cm,
       線條請用黑色、夠粗、夠清楚,確保四個角都完整印在紙上)。
    2. 把咖啡粉「均勻攤平、盡量不重疊」地散布在正方形框「內部」。
       咖啡粉本身比白紙深色,反差足夠,不需要額外背景。
    3. 垂直由上往下拍照,讓正方形的四個角都完整入鏡,光線均勻無強烈陰影。
    4. 程式會自動偵測這個正方形外框的四個角,做透視校正(把畫面攤平、
       自動修正拍歪的角度),並依框的實際邊長(預設 150mm)自動算出比例尺,
       不需要再額外用尺手動量測。

    若正方形邊長不是 15cm,請用 --square-mm 參數指定實際邊長(單位 mm)。

    【備用做法:手動比例尺,沿用舊版方式】
    若沒有列印校正框,也可以放一把尺或已知尺寸物體入鏡,
    用 --scale 參數手動指定比例尺(每 mm 幾個像素),或用 --calibrate
    模式在影像上點兩下量測。詳見下方「使用方式」。

使用方式:
    # 【推薦】用列印的正方形校正框,自動偵測+透視校正+自動算比例尺
    python coffee_grind_analysis.py --image grounds.jpg --square-mm 150 --outdir results

    # 若程式自動偵測不到正方形外框,手動點選四個角
    python coffee_grind_analysis.py --image grounds.jpg --pick-corners --square-mm 150

    # ---- 以下為舊版「手動比例尺」流程,沒有列印校正框時使用 ----
    # 一般分析(需提供比例尺,單位 px/mm)
    python coffee_grind_analysis.py --image grounds.jpg --scale 25.0 --outdir results

    # 不知道比例尺時,先進入校正小工具,在影像上點兩下量出像素距離
    python coffee_grind_analysis.py --image grounds.jpg --calibrate

    # 背景是淺色、咖啡粉是深色(預設),若相反請加 --invert
    python coffee_grind_analysis.py --image grounds.jpg --scale 25.0 --invert

依賴套件:
    pip install opencv-python numpy scipy pandas matplotlib --break-system-packages
"""

import argparse
import os
import sys
import cv2
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def order_corners(pts):
    """將 4 個角點依「左上、右上、右下、左下」順序排列"""
    pts = np.array(pts, dtype="float32")
    s = pts.sum(axis=1)
    diff = np.diff(pts, axis=1).flatten()
    tl = pts[np.argmin(s)]
    br = pts[np.argmax(s)]
    tr = pts[np.argmin(diff)]
    bl = pts[np.argmax(diff)]
    return np.array([tl, tr, br, bl], dtype="float32")


def find_square_corners(image, min_area_ratio=0.10, max_area_ratio=0.97,
                         side_ratio_tolerance=1.35):
    """
    自動偵測影像中列印的正方形外框,回傳排序好的 4 個角點 (TL,TR,BR,BL)。
    找不到時回傳 None。

    做法:邊緣偵測 -> 找輪廓 -> 找出近似四邊形且四邊長度相近(接近正方形)
          且面積夠大的候選框,取面積最大者。
    """
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 30, 100)
    edges = cv2.dilate(edges, np.ones((5, 5), np.uint8), iterations=2)
    edges = cv2.erode(edges, np.ones((3, 3), np.uint8), iterations=1)

    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    img_area = image.shape[0] * image.shape[1]

    candidates = []
    for cnt in contours:
        area = cv2.contourArea(cnt)
        if area < img_area * min_area_ratio or area > img_area * max_area_ratio:
            continue
        peri = cv2.arcLength(cnt, True)
        approx = cv2.approxPolyDP(cnt, 0.02 * peri, True)
        if len(approx) != 4 or not cv2.isContourConvex(approx):
            continue
        pts = approx.reshape(4, 2).astype("float32")
        ordered = order_corners(pts)
        sides = [np.linalg.norm(ordered[i] - ordered[(i + 1) % 4]) for i in range(4)]
        if max(sides) / min(sides) > side_ratio_tolerance:
            continue  # 四邊長度差太多,不像正方形
        candidates.append((area, ordered))

    if not candidates:
        return None

    candidates.sort(key=lambda x: -x[0])
    return candidates[0][1]


def warp_to_square(image, corners, square_mm, px_per_mm):
    """
    將偵測到的正方形區域做透視變換,攤平成正視圖。
    回傳 (warped_image, scale_px_per_mm)
    """
    size_px = int(round(square_mm * px_per_mm))
    dst = np.array([
        [0, 0],
        [size_px - 1, 0],
        [size_px - 1, size_px - 1],
        [0, size_px - 1],
    ], dtype="float32")
    M = cv2.getPerspectiveTransform(corners, dst)
    warped = cv2.warpPerspective(image, M, (size_px, size_px))
    return warped, px_per_mm


def draw_square_overlay(image, corners):
    """在原圖上畫出偵測到的正方形框,供使用者檢查偵測是否正確"""
    out = image.copy()
    pts = corners.astype(int)
    cv2.polylines(out, [pts], isClosed=True, color=(0, 0, 255), thickness=4)
    for i, p in enumerate(pts):
        cv2.circle(out, tuple(p), 10, (0, 255, 255), -1)
        cv2.putText(out, str(i), tuple(p + 15), cv2.FONT_HERSHEY_SIMPLEX,
                    1.0, (0, 255, 255), 2)
    return out


def run_corner_picker(image_path):
    """
    互動式手動標出正方形 4 個角:依序點選「左上、右上、右下、左下」。
    當自動偵測失敗時使用。需要本機顯示視窗環境。
    回傳排序好的 4 個角點 (numpy array),取消則回傳 None。
    """
    image = cv2.imread(image_path)
    if image is None:
        print(f"無法讀取影像: {image_path}")
        sys.exit(1)

    points = []
    display = image.copy()
    window = "Click corners in order: TL, TR, BR, BL - then press any key"

    def on_click(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN and len(points) < 4:
            points.append((x, y))
            cv2.circle(display, (x, y), 8, (0, 0, 255), -1)
            cv2.putText(display, str(len(points) - 1), (x + 10, y),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 0, 255), 2)
            if len(points) > 1:
                cv2.line(display, points[-2], points[-1], (0, 255, 0), 2)
            if len(points) == 4:
                cv2.line(display, points[3], points[0], (0, 255, 0), 2)
            cv2.imshow(window, display)

    cv2.namedWindow(window)
    cv2.setMouseCallback(window, on_click)
    cv2.imshow(window, display)
    print("請依序點選正方形的「左上 -> 右上 -> 右下 -> 左下」4 個角,完成後按任意鍵。")
    cv2.waitKey(0)
    cv2.destroyAllWindows()

    if len(points) != 4:
        print("未取得 4 個角點,取消。")
        return None

    return np.array(points, dtype="float32")


# --------------------------------------------------------------------------- #
# 核心分析函式
# --------------------------------------------------------------------------- #

def preprocess_image(image, invert=False, blur_ksize=5):
    """灰階化 + 模糊降噪 + 自動二值化 (Otsu)"""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (blur_ksize, blur_ksize), 0)

    thresh_type = cv2.THRESH_BINARY_INV if not invert else cv2.THRESH_BINARY
    _, binary = cv2.threshold(
        blurred, 0, 255, thresh_type + cv2.THRESH_OTSU
    )

    # 形態學處理:去除小雜訊、補小空洞
    kernel = np.ones((3, 3), np.uint8)
    binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel, iterations=1)
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=1)

    return gray, binary


def watershed_split(binary, scale_px_per_mm=10.0, kernel_size=None, dist_thresh=0.5):
    """
    使用 Watershed 演算法分離互相黏在一起的顆粒。
    使用自適應局部最大值 (local maxima) 作為前景種子點。
    回傳每個顆粒的標籤影像 (labels),背景為 0。
    """
    # 距離轉換,找出每個顆粒的「核心」
    dist = cv2.distanceTransform(binary, cv2.DIST_L2, 5)

    if kernel_size is None:
        # 自適應局部最大值核大小 (以物理尺寸約 0.5 mm 作為預設核寬度)
        kernel_size = int(round(0.5 * scale_px_per_mm))
        if kernel_size % 2 == 0:
            kernel_size += 1
        kernel_size = max(3, kernel_size)

    # 用影像膨脹 (dilate) 尋找局部峰值 (local peaks)
    local_max = cv2.dilate(dist, np.ones((kernel_size, kernel_size), np.uint8))
    # 必須同時滿足: 1. 是局部最大值 2. 在前景區域內 3. 距離大於特定像素門檻 (避免平面雜訊)
    sure_fg = (dist == local_max) & (binary > 0) & (dist > dist_thresh)
    sure_fg = sure_fg.astype(np.uint8) * 255

    sure_bg = cv2.dilate(binary, np.ones((3, 3), np.uint8), iterations=2)
    unknown = cv2.subtract(sure_bg, sure_fg)

    n_labels, markers = cv2.connectedComponents(sure_fg)
    markers = markers + 1
    markers[unknown == 255] = 0

    color_img = cv2.cvtColor(binary, cv2.COLOR_GRAY2BGR)
    markers = cv2.watershed(color_img, markers)

    return markers


def extract_particles(markers, gray_shape, scale_px_per_mm,
                       min_diameter_um=20, max_diameter_um=2000,
                       min_circularity=0.5):
    """
    從 watershed 標籤影像中,逐一計算每顆顆粒的等效圓直徑。
    回傳 DataFrame: id, area_px, equiv_diameter_px, equiv_diameter_um, cx, cy, circularity, contour
    """
    records = []
    h, w = gray_shape

    for label in np.unique(markers):
        if label <= 1:  # 0=未知, 1=背景
            continue

        mask = np.uint8(markers == label) * 255
        # 修正分水嶺演算法所造成的邊界收縮 (watershed lines): 膨脹 1 像素以還原邊界
        kernel = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))
        mask = cv2.dilate(mask, kernel, iterations=1)

        contours, _ = cv2.findContours(
            mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        if not contours:
            continue
        cnt = max(contours, key=cv2.contourArea)
        area_px = cv2.contourArea(cnt)
        perimeter_px = cv2.arcLength(cnt, True)
        if area_px <= 0 or perimeter_px <= 0:
            continue

        # 計算圓形度 (circularity = 4 * pi * area / perimeter^2)
        circularity = (4 * np.pi * area_px) / (perimeter_px ** 2)

        # 過濾貼在邊界上的顆粒(可能被裁切,量測不準)
        x, y, bw, bh = cv2.boundingRect(cnt)
        touches_border = x <= 1 or y <= 1 or (x + bw) >= w - 1 or (y + bh) >= h - 1

        equiv_diameter_px = np.sqrt(4 * area_px / np.pi)
        equiv_diameter_um = (equiv_diameter_px / scale_px_per_mm) * 1000.0

        M = cv2.moments(cnt)
        cx = M["m10"] / M["m00"] if M["m00"] != 0 else x + bw / 2
        cy = M["m01"] / M["m00"] if M["m00"] != 0 else y + bh / 2

        records.append({
            "id": int(label),
            "area_px": area_px,
            "equiv_diameter_px": equiv_diameter_px,
            "equiv_diameter_um": equiv_diameter_um,
            "circularity": circularity,
            "cx": cx,
            "cy": cy,
            "touches_border": touches_border,
            "contour": cnt,
        })

    df = pd.DataFrame(records)
    if df.empty:
        return df

    # 過濾不合理的尺寸(雜訊或過度黏連未分離乾淨的大團塊)與低圓形度的結塊
    df = df[
        (df["equiv_diameter_um"] >= min_diameter_um)
        & (df["equiv_diameter_um"] <= max_diameter_um)
        & (df["circularity"] >= min_circularity)
        & (~df["touches_border"])
    ].reset_index(drop=True)

    return df


def compute_statistics(diam_um):
    """計算粒徑分布統計值,包含數量分佈與體積分佈的 D10 / D50 / D90"""
    diam_um = np.asarray(diam_um)
    stats = {
        "count": len(diam_um),
        "mean_um": np.mean(diam_um),
        "median_um": np.median(diam_um),
        "std_um": np.std(diam_um),
        "min_um": np.min(diam_um),
        "max_um": np.max(diam_um),
        "Dn10_um": np.percentile(diam_um, 10),
        "Dn50_um": np.percentile(diam_um, 50),
        "Dn90_um": np.percentile(diam_um, 90),
    }
    # 向後相容
    stats["D10_um"] = stats["Dn10_um"]
    stats["D50_um"] = stats["Dn50_um"]
    stats["D90_um"] = stats["Dn90_um"]

    # 體積分佈統計 (以球體體積 V = pi/6 * d^3 權重計算)
    if len(diam_um) > 0:
        sort_idx = np.argsort(diam_um)
        diam_sorted = diam_um[sort_idx]
        volumes_sorted = (np.pi / 6.0) * (diam_sorted ** 3)
        cum_vol = np.cumsum(volumes_sorted)
        cum_vol_pct = cum_vol / cum_vol[-1] * 100.0

        stats["Dv10_um"] = np.interp(10.0, cum_vol_pct, diam_sorted)
        stats["Dv50_um"] = np.interp(50.0, cum_vol_pct, diam_sorted)
        stats["Dv90_um"] = np.interp(90.0, cum_vol_pct, diam_sorted)
    else:
        stats["Dv10_um"] = 0.0
        stats["Dv50_um"] = 0.0
        stats["Dv90_um"] = 0.0

    return stats


def draw_annotated_image(image, df):
    """在原圖上框出每顆被偵測到的顆粒並標上編號"""
    out = image.copy()
    for _, row in df.iterrows():
        cv2.drawContours(out, [row["contour"]], -1, (0, 255, 0), 1)
        cx, cy = int(row["cx"]), int(row["cy"])
        cv2.circle(out, (cx, cy), 1, (0, 0, 255), -1)
    return out


def _setup_cjk_font():
    """嘗試尋找系統內可用的中文字型,找不到則回傳 False(改用英文標籤)"""
    import matplotlib.font_manager as fm
    candidates = [
        "Noto Sans CJK TC", "Noto Sans CJK SC", "Noto Sans TC", "Noto Sans SC",
        "Microsoft JhengHei", "PingFang TC", "PingFang SC", "SimHei",
        "WenQuanYi Zen Hei", "Heiti TC", "Arial Unicode MS",
    ]
    available = {f.name for f in fm.fontManager.ttflist}
    for name in candidates:
        if name in available:
            plt.rcParams["font.sans-serif"] = [name]
            plt.rcParams["axes.unicode_minus"] = False
            return True
    return False


_HAS_CJK_FONT = _setup_cjk_font()


def plot_histogram(diam_um, stats, outpath, bins=40):
    """繪製粒徑分布直方圖,並標示 D10/D50/D90"""
    if _HAS_CJK_FONT:
        xlabel, ylabel = "等效顆粒直徑 (μm)", "顆粒數量"
        title = f"咖啡粉粒徑分布 (n={stats['count']})"
        d_labels = {"D10_um": "D10", "D50_um": "D50 (中位數)", "D90_um": "D90"}
    else:
        xlabel, ylabel = "Equivalent Diameter (um)", "Particle Count"
        title = f"Coffee Grind Particle Size Distribution (n={stats['count']})"
        d_labels = {"D10_um": "D10", "D50_um": "D50 (median)", "D90_um": "D90"}

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.hist(diam_um, bins=bins, color="#6f4e37", edgecolor="white", alpha=0.85)

    for key, color in [
        ("D10_um", "#1f77b4"),
        ("D50_um", "#2ca02c"),
        ("D90_um", "#d62728"),
    ]:
        ax.axvline(stats[key], color=color, linestyle="--", linewidth=1.5,
                    label=f"{d_labels[key]} = {stats[key]:.0f} um")

    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend()
    fig.tight_layout()
    fig.savefig(outpath, dpi=150)
    plt.close(fig)


def plot_volume_histogram(diam_um, stats, outpath, bins=40):
    """繪製體積粒徑分布直方圖,並標示 Dv10/Dv50/Dv90"""
    diam_um = np.asarray(diam_um)
    if len(diam_um) == 0:
        return
    volumes = (np.pi / 6.0) * (diam_um ** 3)
    weights = (volumes / np.sum(volumes)) * 100.0

    if _HAS_CJK_FONT:
        xlabel, ylabel = "等效顆粒直徑 (μm)", "體積百分比 (%)"
        title = f"咖啡粉體積粒徑分布 (n={stats['count']})"
        d_labels = {"Dv10_um": "Dv10", "Dv50_um": "Dv50 (中位體積)", "Dv90_um": "Dv90"}
    else:
        xlabel, ylabel = "Equivalent Diameter (um)", "Volume Percentage (%)"
        title = f"Coffee Grind Volume Distribution (n={stats['count']})"
        d_labels = {"Dv10_um": "Dv10", "Dv50_um": "Dv50 (median volume)", "Dv90_um": "Dv90"}

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.hist(diam_um, bins=bins, weights=weights, color="#3e2723", edgecolor="white", alpha=0.85)

    for key, color in [
        ("Dv10_um", "#1f77b4"),
        ("Dv50_um", "#2ca02c"),
        ("Dv90_um", "#d62728"),
    ]:
        ax.axvline(stats[key], color=color, linestyle="--", linewidth=1.5,
                    label=f"{d_labels[key]} = {stats[key]:.0f} um")

    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend()
    fig.tight_layout()
    fig.savefig(outpath, dpi=150)
    plt.close(fig)


# --------------------------------------------------------------------------- #
# 比例尺校正小工具
# --------------------------------------------------------------------------- #

def run_calibration_tool(image_path):
    """
    互動式比例尺校正:在影像上點兩下,標出已知長度的兩端點,
    程式會自動算出像素距離,使用者再輸入該段的實際長度(mm),
    最後印出 PIXELS_PER_MM 供 --scale 參數使用。
    需要有顯示視窗的環境(本機執行,非純終端伺服器)。
    """
    image = cv2.imread(image_path)
    if image is None:
        print(f"無法讀取影像: {image_path}")
        sys.exit(1)

    points = []
    display = image.copy()

    def on_click(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN and len(points) < 2:
            points.append((x, y))
            cv2.circle(display, (x, y), 5, (0, 0, 255), -1)
            if len(points) == 2:
                cv2.line(display, points[0], points[1], (0, 255, 0), 2)
            cv2.imshow("Calibration - click two points, then press any key", display)

    cv2.namedWindow("Calibration - click two points, then press any key")
    cv2.setMouseCallback("Calibration - click two points, then press any key", on_click)
    cv2.imshow("Calibration - click two points, then press any key", display)
    print("請在跳出的視窗中,於已知長度物體(例如尺上的刻度)的兩端各點一下,完成後按任意鍵。")
    cv2.waitKey(0)
    cv2.destroyAllWindows()

    if len(points) != 2:
        print("未取得兩個點,校正取消。")
        return

    pixel_dist = np.linalg.norm(np.array(points[0]) - np.array(points[1]))
    real_mm = float(input(f"像素距離 = {pixel_dist:.1f} px,請輸入這段距離的實際長度(mm): "))
    px_per_mm = pixel_dist / real_mm
    print(f"\n>>> 比例尺 PIXELS_PER_MM = {px_per_mm:.4f}")
    print(f">>> 之後請用: --scale {px_per_mm:.4f}\n")


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #

def _run_particle_pipeline(image, scale_px_per_mm, outdir, invert,
                            min_diameter_um, max_diameter_um, source_label="",
                            watershed_kernel=None, dist_thresh=0.5,
                            min_circularity=0.5):
    """共用的顆粒偵測 + 統計 + 輸出流程,輸入已經是「待分析的影像」"""
    print("影像前處理中...")
    gray, binary = preprocess_image(image, invert=invert)

    print("進行顆粒分離 (watershed)...")
    markers = watershed_split(
        binary, scale_px_per_mm=scale_px_per_mm,
        kernel_size=watershed_kernel, dist_thresh=dist_thresh
    )

    print("計算每顆顆粒的粒徑...")
    df = extract_particles(
        markers, gray.shape, scale_px_per_mm,
        min_diameter_um=min_diameter_um, max_diameter_um=max_diameter_um,
        min_circularity=min_circularity
    )

    if df.empty:
        print("沒有偵測到有效顆粒,請檢查:")
        print("  - 咖啡粉與紙張背景的顏色反差是否足夠")
        print("  - 是否需要加上 --invert 參數")
        print("  - 顆粒是否太過重疊、或框內咖啡粉太少")
        sys.exit(1)

    print(f"   共偵測到 {len(df)} 顆有效顆粒{source_label}")

    print("計算統計數據與繪圖...")
    stats = compute_statistics(df["equiv_diameter_um"].values)

    annotated = draw_annotated_image(image, df)
    annotated_path = os.path.join(outdir, "annotated.jpg")
    cv2.imwrite(annotated_path, annotated)

    binary_path = os.path.join(outdir, "binary_mask.jpg")
    cv2.imwrite(binary_path, binary)

    hist_path = os.path.join(outdir, "histogram.png")
    plot_histogram(df["equiv_diameter_um"].values, stats, hist_path)

    vol_hist_path = os.path.join(outdir, "volume_histogram.png")
    plot_volume_histogram(df["equiv_diameter_um"].values, stats, vol_hist_path)

    print("輸出資料檔...")
    csv_path = os.path.join(outdir, "particles.csv")
    df.drop(columns=["contour"]).to_csv(csv_path, index=False, encoding="utf-8-sig")

    summary_path = os.path.join(outdir, "summary.txt")
    with open(summary_path, "w", encoding="utf-8") as f:
        f.write("咖啡粉粒徑分析結果摘要\n")
        f.write("=" * 30 + "\n")
        f.write(f"scale_px_per_mm: {scale_px_per_mm:.4f}\n")
        for k, v in stats.items():
            f.write(f"{k}: {v:.2f}\n" if isinstance(v, float) else f"{k}: {v}\n")

    print("\n===== 分析完成 =====")
    print(f"  使用比例尺 scale_px_per_mm = {scale_px_per_mm:.4f}")
    for k, v in stats.items():
        print(f"  {k}: {v:.2f}" if isinstance(v, float) else f"  {k}: {v}")
    print(f"\n輸出檔案位於: {os.path.abspath(outdir)}")
    print(f"  - annotated.jpg          (標註顆粒後的照片)")
    print(f"  - binary_mask.jpg        (二值化遮罩,可用來檢查偵測效果)")
    print(f"  - histogram.png          (數量粒徑分布直方圖)")
    print(f"  - volume_histogram.png   (體積粒徑分布直方圖)")
    print(f"  - particles.csv          (每顆顆粒的詳細資料)")
    print(f"  - summary.txt            (統計摘要)")


def analyze_with_square(image_path, outdir, square_mm=150.0, resolution_px_per_mm=10.0,
                         manual_corners=None, invert=False,
                         min_diameter_um=20, max_diameter_um=2000,
                         margin_mm=2.0, watershed_kernel=None, dist_thresh=0.5,
                         min_circularity=0.5):
    """
    【推薦流程】用列印的正方形校正框做分析:
    自動(或手動)偵測 4 個角 -> 透視校正攤平 -> 依框邊長自動算比例尺 -> 分析框內顆粒
    """
    os.makedirs(outdir, exist_ok=True)

    image = cv2.imread(image_path)
    if image is None:
        print(f"無法讀取影像: {image_path}")
        sys.exit(1)

    if manual_corners is not None:
        corners = manual_corners
        print("使用手動指定的角點。")
    else:
        print("1/6 自動偵測正方形校正框...")
        corners = find_square_corners(image)
        if corners is None:
            print("\n找不到正方形校正框,可能原因:")
            print("  - 框線不夠清楚、太細、或與背景反差不足")
            print("  - 四個角沒有完整入鏡")
            print("  - 框被咖啡粉蓋住一部分")
            print("\n請改用手動點選角點: 加上 --pick-corners 參數重新執行")
            sys.exit(1)

    overlay = draw_square_overlay(image, corners)
    overlay_path = os.path.join(outdir, "square_detection.jpg")
    cv2.imwrite(overlay_path, overlay)
    print(f"   已儲存 square_detection.jpg,請務必檢查紅框是否準確貼合正方形邊界。")

    print("2/6 透視校正、攤平影像...")
    warped, scale_px_per_mm = warp_to_square(image, corners, square_mm, resolution_px_per_mm)
    warped_path = os.path.join(outdir, "warped.jpg")
    cv2.imwrite(warped_path, warped)

    # 內縮邊界,避免框線本身被當成顆粒邊緣、以及框邊上被切到一半的顆粒
    margin_px = int(round(margin_mm * scale_px_per_mm))
    h, w = warped.shape[:2]
    margin_px = max(0, min(margin_px, h // 4, w // 4))
    cropped = warped[margin_px:h - margin_px, margin_px:w - margin_px]

    print(f"3/6 自動比例尺 = {scale_px_per_mm:.4f} px/mm "
          f"(校正框邊長 {square_mm:.1f} mm)")

    print("4-6/6 分析框內咖啡粉顆粒...")
    _run_particle_pipeline(
        cropped, scale_px_per_mm, outdir, invert,
        min_diameter_um, max_diameter_um,
        source_label=f"(校正框內,邊長 {square_mm:.0f}mm)",
        watershed_kernel=watershed_kernel, dist_thresh=dist_thresh,
        min_circularity=min_circularity
    )


def analyze_legacy_scale(image_path, scale_px_per_mm, outdir, invert=False,
                          min_diameter_um=20, max_diameter_um=2000,
                          watershed_kernel=None, dist_thresh=0.5,
                          min_circularity=0.5):
    """【舊版流程】使用者手動提供比例尺(沒有列印校正框時使用)"""
    os.makedirs(outdir, exist_ok=True)
    image = cv2.imread(image_path)
    if image is None:
        print(f"無法讀取影像: {image_path}")
        sys.exit(1)

    _run_particle_pipeline(
        image, scale_px_per_mm, outdir, invert,
        min_diameter_um, max_diameter_um,
        watershed_kernel=watershed_kernel, dist_thresh=dist_thresh,
        min_circularity=min_circularity
    )


def parse_corners_arg(s):
    """解析 --corners 字串,格式: 'x1,y1;x2,y2;x3,y3;x4,y4' (TL,TR,BR,BL 順序)"""
    try:
        pts = []
        for part in s.strip().split(";"):
            x_str, y_str = part.split(",")
            pts.append([float(x_str), float(y_str)])
        if len(pts) != 4:
            raise ValueError
        return np.array(pts, dtype="float32")
    except Exception:
        print("錯誤: --corners 格式應為 'x1,y1;x2,y2;x3,y3;x4,y4' (左上,右上,右下,左下)")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="咖啡粉粒徑分析程式")
    parser.add_argument("--image", required=True, help="咖啡粉照片路徑")
    parser.add_argument("--outdir", default="results", help="輸出資料夾")
    parser.add_argument("--invert", action="store_true",
                         help="若咖啡粉顏色「比背景淺」,請加此參數")
    parser.add_argument("--min-diameter-um", type=float, default=20,
                         help="過濾掉小於此值的雜訊顆粒(微米),預設 20")
    parser.add_argument("--max-diameter-um", type=float, default=2000,
                         help="過濾掉大於此值的異常顆粒(微米),預設 2000")

    # ---- 推薦流程:列印正方形校正框 ----
    parser.add_argument("--square-mm", type=float, default=150.0,
                         help="列印的正方形校正框邊長(mm),預設 150 (15cm x 15cm)")
    parser.add_argument("--resolution", type=float, default=10.0,
                         help="透視校正後輸出影像的解析度(每 mm 幾個像素),"
                              "預設 10。數值越高細節越清楚但檔案越大")
    parser.add_argument("--margin-mm", type=float, default=2.0,
                         help="校正框內縮邊界(mm),避免框線本身被誤判,預設 2")
    parser.add_argument("--pick-corners", action="store_true",
                         help="手動點選正方形 4 個角(自動偵測失敗時使用,"
                              "需要本機顯示視窗環境)")
    parser.add_argument("--corners", type=str, default=None,
                         help="直接指定 4 個角點座標,格式 'x1,y1;x2,y2;x3,y3;x4,y4'"
                              "(左上,右上,右下,左下),跳過自動偵測")
    parser.add_argument("--watershed-kernel", type=int, default=None,
                         help="分水嶺演算法局部最大值核大小(像素),預設為自動根據解析度計算")
    parser.add_argument("--dist-thresh", type=float, default=0.5,
                         help="分水嶺演算法種子點距離轉換門檻值(像素),預設 0.5")
    parser.add_argument("--min-circularity", type=float, default=0.5,
                         help="篩選掉圓形度(circularity)小於此值的顆粒以排除大型結塊,預設 0.5。設為 0.0 表示不篩選")

    # ---- 舊版流程:手動比例尺(沒有列印校正框時) ----
    parser.add_argument("--scale", type=float, default=None,
                         help="[舊版流程] 比例尺,每公釐(mm)對應幾個像素(px)。"
                              "提供此參數即改用舊版流程,不做正方形偵測。")
    parser.add_argument("--calibrate", action="store_true",
                         help="[舊版流程] 進入互動式比例尺校正模式(點兩下量距離)")

    args = parser.parse_args()

    # 舊版流程
    if args.calibrate:
        run_calibration_tool(args.image)
        return

    if args.scale is not None:
        analyze_legacy_scale(
            args.image, args.scale, args.outdir,
            invert=args.invert,
            min_diameter_um=args.min_diameter_um,
            max_diameter_um=args.max_diameter_um,
            watershed_kernel=args.watershed_kernel,
            dist_thresh=args.dist_thresh,
            min_circularity=args.min_circularity,
        )
        return

    # 新版流程(正方形校正框)
    manual_corners = None
    if args.pick_corners:
        manual_corners = run_corner_picker(args.image)
        if manual_corners is None:
            sys.exit(1)
    elif args.corners:
        manual_corners = parse_corners_arg(args.corners)

    analyze_with_square(
        args.image, args.outdir,
        square_mm=args.square_mm,
        resolution_px_per_mm=args.resolution,
        manual_corners=manual_corners,
        invert=args.invert,
        min_diameter_um=args.min_diameter_um,
        max_diameter_um=args.max_diameter_um,
        margin_mm=args.margin_mm,
        watershed_kernel=args.watershed_kernel,
        dist_thresh=args.dist_thresh,
        min_circularity=args.min_circularity,
    )


if __name__ == "__main__":
    main()