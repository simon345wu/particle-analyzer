import argparse
import os
import subprocess
import numpy as np
import pandas as pd
import cv2

def main():
    parser = argparse.ArgumentParser(description="Generate synthetic particle image and validate analyzer")
    parser.add_argument("--d50", type=float, default=500.0, help="Target Dn50 (median diameter) in um")
    parser.add_argument("--d10", type=float, default=350.0, help="Target Dn10 diameter in um")
    parser.add_argument("--d90", type=float, default=650.0, help="Target Dn90 diameter in um")
    parser.add_argument("--num-particles", type=int, default=400, help="Number of particles to generate")
    parser.add_argument("--scale", type=float, default=50.0, help="Scale of the image in pixels/mm")
    parser.add_argument("--width", type=int, default=2000, help="Image width in pixels")
    parser.add_argument("--height", type=int, default=2000, help="Image height in pixels")
    parser.add_argument("--output-img", default="synthetic_particles.jpg", help="Output path for synthetic image")
    parser.add_argument("--output-dir", default="synthetic_results", help="Output directory for analyzer results")
    args = parser.parse_args()

    # Calculate Gaussian distribution parameters (mu, sigma)
    # Dn10 = mu - 1.28155 * sigma
    # Dn90 = mu + 1.28155 * sigma
    # => sigma = (Dn90 - Dn10) / 2.5631
    mu = args.d50
    sigma = (args.d90 - args.d10) / 2.5631
    
    if sigma <= 0:
        print("Error: D90 must be greater than D10")
        return

    print("=" * 60)
    print("Step 1: Generating Particle Size Distribution (Normal Distribution)")
    print("=" * 60)
    print(f"Target distribution parameters:")
    print(f"  Theoretical Dn10: {args.d10:.1f} um")
    print(f"  Theoretical Dn50: {args.d50:.1f} um")
    print(f"  Theoretical Dn90: {args.d90:.1f} um")
    print(f"  Gaussian Mean (mu): {mu:.1f} um, Std Dev (sigma): {sigma:.1f} um")
    
    # Generate diameters
    diameters_um = []
    attempts = 0
    # Generate raw normal distribution and filter out invalid values (< 20 um or > 2000 um)
    while len(diameters_um) < args.num_particles and attempts < 100000:
        val = np.random.normal(mu, sigma)
        if 20.0 <= val <= 2000.0:
            diameters_um.append(val)
        attempts += 1
    
    diameters_um = np.array(diameters_um)
    print(f"Generated {len(diameters_um)} particle diameters.")

    # Sort to compute exact sample percentiles
    diameters_sorted = np.sort(diameters_um)
    sample_dn10 = np.percentile(diameters_sorted, 10)
    sample_dn50 = np.percentile(diameters_sorted, 50)
    sample_dn90 = np.percentile(diameters_sorted, 90)
    sample_mean = np.mean(diameters_sorted)
    sample_std = np.std(diameters_sorted)

    # Volume distribution stats for sample
    volumes = (np.pi / 6.0) * (diameters_sorted ** 3)
    cum_vol_pct = np.cumsum(volumes) / np.sum(volumes) * 100.0
    sample_dv10 = np.interp(10.0, cum_vol_pct, diameters_sorted)
    sample_dv50 = np.interp(50.0, cum_vol_pct, diameters_sorted)
    sample_dv90 = np.interp(90.0, cum_vol_pct, diameters_sorted)

    print(f"\nInitial Sample Ground Truth (Number-based):")
    print(f"  Sample Dn10: {sample_dn10:.2f} um")
    print(f"  Sample Dn50: {sample_dn50:.2f} um")
    print(f"  Sample Dn90: {sample_dn90:.2f} um")
    print(f"  Sample Mean: {sample_mean:.2f} um")

    # Create image canvas (white background)
    img = np.ones((args.height, args.width, 3), dtype=np.uint8) * 255

    placed_particles = [] # list of (x, y, r_px, d_um)
    margin = 50 # margin from border
    min_spacing = 10 # minimum distance between particle edges in pixels to prevent watershed issues

    print("\nPlacing particles on canvas (avoiding overlaps)...")
    for d_um in diameters_sorted:
        # Convert diameter um to pixels
        # scale is pixels/mm, 1 mm = 1000 um
        # d_px = d_um * (scale / 1000)
        d_px = d_um * (args.scale / 1000.0)
        r_px = d_px / 2.0
        
        placed = False
        # Try to place particle randomly without overlap
        for _ in range(1000):
            x = np.random.uniform(margin + r_px, args.width - margin - r_px)
            y = np.random.uniform(margin + r_px, args.height - margin - r_px)
            
            # Check overlap
            overlap = False
            for px in placed_particles:
                dist = np.sqrt((x - px[0])**2 + (y - px[1])**2)
                if dist < (r_px + px[2] + min_spacing):
                    overlap = True
                    break
            
            if not overlap:
                placed_particles.append((x, y, r_px, d_um))
                placed = True
                break
        
        if not placed:
            print(f"Warning: Could not place particle of size {d_um:.1f} um (too crowded)")

    print(f"Successfully placed {len(placed_particles)} / {len(diameters_um)} particles.")

    # Draw the placed particles
    for p in placed_particles:
        cx, cy, r_px, d_um = p
        # Draw particle as filled circle (dark brown to simulate coffee)
        # Coffee color: (40, 30, 25) in BGR
        cv2.circle(img, (int(round(cx)), int(round(cy))), int(round(r_px)), (25, 30, 40), -1)

    # Save synthetic image
    cv2.imwrite(args.output_img, img)
    print(f"Saved synthetic image to {args.output_img}")

    # Re-calculate actual placed ground truth statistics
    placed_diameters_um = np.array([p[3] for p in placed_particles])
    placed_diameters_sorted = np.sort(placed_diameters_um)
    gt_count = len(placed_diameters_sorted)
    gt_dn10 = np.percentile(placed_diameters_sorted, 10)
    gt_dn50 = np.percentile(placed_diameters_sorted, 50)
    gt_dn90 = np.percentile(placed_diameters_sorted, 90)
    gt_mean = np.mean(placed_diameters_sorted)
    gt_std = np.std(placed_diameters_sorted)

    gt_vol = (np.pi / 6.0) * (placed_diameters_sorted ** 3)
    gt_cum_vol_pct = np.cumsum(gt_vol) / np.sum(gt_vol) * 100.0
    gt_dv10 = np.interp(10.0, gt_cum_vol_pct, placed_diameters_sorted)
    gt_dv50 = np.interp(50.0, gt_cum_vol_pct, placed_diameters_sorted)
    gt_dv90 = np.interp(90.0, gt_cum_vol_pct, placed_diameters_sorted)

    print("\n" + "=" * 60)
    print("Step 2: Running Coffee Grind Analyzer")
    print("=" * 60)

    # Run the coffee grind analysis script on this image
    cmd = [
        "python",
        "coffee_grind_analysis.py",
        "--image", args.output_img,
        "--scale", str(args.scale),
        "--outdir", args.output_dir
    ]
    print(f"Running analysis program: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    
    if result.returncode != 0:
        print("Analysis program failed with error:")
        print(result.stderr)
        return
    
    print("Analysis program completed successfully!")

    # Read the results summary
    summary_txt_path = os.path.join(args.output_dir, "summary.txt")
    if not os.path.exists(summary_txt_path):
        print(f"Error: summary file not found at {summary_txt_path}")
        return

    detected_stats = {}
    with open(summary_txt_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
        for line in lines:
            if ":" in line:
                parts = line.strip().split(":")
                k = parts[0].strip()
                try:
                    v = float(parts[1].strip())
                    detected_stats[k] = v
                except ValueError:
                    detected_stats[k] = parts[1].strip()

    # Compare ground truth and detected
    det_count = int(detected_stats.get("count", 0))
    det_dn10 = detected_stats.get("Dn10_um", 0.0)
    det_dn50 = detected_stats.get("Dn50_um", 0.0)
    det_dn90 = detected_stats.get("Dn90_um", 0.0)
    det_mean = detected_stats.get("mean_um", 0.0)
    det_std = detected_stats.get("std_um", 0.0)
    det_dv10 = detected_stats.get("Dv10_um", 0.0)
    det_dv50 = detected_stats.get("Dv50_um", 0.0)
    det_dv90 = detected_stats.get("Dv90_um", 0.0)

    # Calculate absolute differences and relative errors
    def calc_error(gt, det):
        if gt == 0:
            return 0.0
        return ((det - gt) / gt) * 100.0

    print("\n" + "="*80)
    print("                      PARTICLE ANALYZER VALIDATION REPORT                      ")
    print("="*80)
    print(f"{'Metric':<15} | {'Ground Truth':<15} | {'Detected':<15} | {'Error (%)':<15}")
    print("-"*80)
    print(f"{'Count':<15} | {gt_count:<15d} | {det_count:<15d} | {calc_error(gt_count, det_count):<15.2f}%")
    print(f"{'Mean (um)':<15} | {gt_mean:<15.2f} | {det_mean:<15.2f} | {calc_error(gt_mean, det_mean):<15.2f}%")
    print(f"{'Std Dev (um)':<15} | {gt_std:<15.2f} | {det_std:<15.2f} | {calc_error(gt_std, det_std):<15.2f}%")
    print("-"*80)
    print(f"{'Dn10 (um)':<15} | {gt_dn10:<15.2f} | {det_dn10:<15.2f} | {calc_error(gt_dn10, det_dn10):<15.2f}%")
    print(f"{'Dn50 (um)':<15} | {gt_dn50:<15.2f} | {det_dn50:<15.2f} | {calc_error(gt_dn50, det_dn50):<15.2f}%")
    print(f"{'Dn90 (um)':<15} | {gt_dn90:<15.2f} | {det_dn90:<15.2f} | {calc_error(gt_dn90, det_dn90):<15.2f}%")
    print("-"*80)
    print(f"{'Dv10 (um)':<15} | {gt_dv10:<15.2f} | {det_dv10:<15.2f} | {calc_error(gt_dv10, det_dv10):<15.2f}%")
    print(f"{'Dv50 (um)':<15} | {gt_dv50:<15.2f} | {det_dv50:<15.2f} | {calc_error(gt_dv50, det_dv50):<15.2f}%")
    print(f"{'Dv90 (um)':<15} | {gt_dv90:<15.2f} | {det_dv90:<15.2f} | {calc_error(gt_dv90, det_dv90):<15.2f}%")
    print("="*80)

    # Save a markdown report to the output directory
    report_path = os.path.join(args.output_dir, "validation_report.md")
    with open(report_path, "w", encoding="utf-8") as rf:
        rf.write("# Particle Size Analyzer Validation Report\n\n")
        rf.write("This report validates the accuracy of the coffee grind particle analyzer script using a synthetically generated test image.\n\n")
        rf.write("## Test Parameters\n")
        rf.write(f"- **Target Normal Distribution**: Dn10 = {args.d10} um, Dn50 = {args.d50} um, Dn90 = {args.d90} um\n")
        rf.write(f"- **Image Size**: {args.width}x{args.height} px\n")
        rf.write(f"- **Scale**: {args.scale} px/mm (1 pixel = {1000/args.scale:.1f} um)\n")
        rf.write(f"- **Number of Particles**: {args.num_particles} generated, {gt_count} successfully placed (non-overlapping)\n\n")
        
        rf.write("## Comparison Results\n\n")
        rf.write(f"| Metric | Ground Truth | Detected | Error (%) |\n")
        rf.write(f"| :--- | :---: | :---: | :---: |\n")
        rf.write(f"| Count | {gt_count} | {det_count} | {calc_error(gt_count, det_count):.2f}% |\n")
        rf.write(f"| Mean (um) | {gt_mean:.2f} | {det_mean:.2f} | {calc_error(gt_mean, det_mean):.2f}% |\n")
        rf.write(f"| Std Dev (um) | {gt_std:.2f} | {det_std:.2f} | {calc_error(gt_std, det_std):.2f}% |\n")
        rf.write(f"| Dn10 (um) | {gt_dn10:.2f} | {det_dn10:.2f} | {calc_error(gt_dn10, det_dn10):.2f}% |\n")
        rf.write(f"| Dn50 (um) | {gt_dn50:.2f} | {det_dn50:.2f} | {calc_error(gt_dn50, det_dn50):.2f}% |\n")
        rf.write(f"| Dn90 (um) | {gt_dn90:.2f} | {det_dn90:.2f} | {calc_error(gt_dn90, det_dn90):.2f}% |\n")
        rf.write(f"| Dv10 (um) | {gt_dv10:.2f} | {det_dv10:.2f} | {calc_error(gt_dv10, det_dv10):.2f}% |\n")
        rf.write(f"| Dv50 (um) | {gt_dv50:.2f} | {det_dv50:.2f} | {calc_error(gt_dv50, det_dv50):.2f}% |\n")
        rf.write(f"| Dv90 (um) | {gt_dv90:.2f} | {det_dv90:.2f} | {calc_error(gt_dv90, det_dv90):.2f}% |\n\n")
        
        rf.write("## Conclusion\n")
        avg_err = np.mean([abs(calc_error(gt_dn10, det_dn10)), abs(calc_error(gt_dn50, det_dn50)), abs(calc_error(gt_dn90, det_dn90))])
        rf.write(f"The average absolute error for the main number percentiles (Dn10, Dn50, Dn90) is **{avg_err:.2f}%**.\n\n")
        if avg_err < 5.0:
            rf.write("The program is **highly accurate** in detecting and sizing particles under standard conditions.\n")
        else:
            rf.write("The program shows some deviation, which could be due to thresholding or morphology effects on smaller particles.\n")

    print(f"Validation report saved to {report_path}")

if __name__ == "__main__":
    main()
