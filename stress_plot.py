import sys
print("Starting script...")
import pandas as pd
import matplotlib
import matplotlib.pyplot as plt
import numpy as np

def create_hrv_plot(csv_path):
    """
    Creates a plot of HRV data by Subject ID and Category (Stressed vs Not).
    Uses pure matplotlib and pandas to avoid extra dependencies.
    """
    try:
        df = pd.read_csv(csv_path)
    except FileNotFoundError:
        print(f"Error: File {csv_path} not found.")
        return

    # Clean up column names in case of leading/trailing spaces
    df.columns = [c.strip() for c in df.columns]

    # Required columns based on HRV.csv: Subject, HRV (ms), Stress or not
    # Ensure they exist
    required = ["Subject", "HRV (ms)", "Stress or not"]
    for col in required:
        if col not in df.columns:
            print(f"Error: Required column '{col}' missing. Found: {list(df.columns)}")
            return

    # Set internal category order
    df['Stress or not'] = pd.Categorical(df['Stress or not'], categories=['Yes', 'No'], ordered=True)
    
    plt.figure(figsize=(14, 8))
    
    # Get unique subjects in order of appearance
    subjects = df['Subject'].unique()
    subject_map = {sub: i for i, sub in enumerate(subjects)}
    
    # Map colors: Orange for Stress (Yes) for better accessibility, Green for No
    colors = {'Yes': '#e67e22', 'No': '#2ecc71'} 
    
    # We want to dodge the points: Yes on left, No on right for each subject
    offset = 0.2 
    box_width = 0.15
    
    # Iterate through subjects to draw box plots, scatter points, and the midpoint marker
    for i, sub in enumerate(subjects):
        medians = {}
        for category in ['Yes', 'No']:
            cat_data = df[(df['Subject'] == sub) & (df['Stress or not'] == category)]['HRV (ms)']
            if cat_data.empty:
                continue
                
            medians[category] = cat_data.median()
            x_pos = i - offset if category == 'Yes' else i + offset
            
            # Draw Box Plot
            plt.boxplot(
                cat_data, 
                positions=[x_pos], 
                widths=box_width,
                patch_artist=True,
                showmeans=True,
                meanline=True,
                medianprops={'color': 'black', 'linewidth': 2},
                meanprops={'color': 'blue', 'linewidth': 2, 'linestyle': '--'},
                boxprops={'facecolor': colors[category], 'alpha': 0.3, 'edgecolor': colors[category]},
                whiskerprops={'color': colors[category]},
                capprops={'color': colors[category]},
                flierprops={'marker': '', 'alpha': 0}
            )
            
            # Add Scatter points on top
            jitter = np.random.uniform(-0.04, 0.04, size=len(cat_data))
            plt.scatter(
                [x_pos] * len(cat_data) + jitter,
                cat_data,
                color=colors[category],
                label='Stressed (Yes)' if category == 'Yes' else 'Not Stressed (No)',
                alpha=0.6,
                edgecolors='gray',
                s=40,
                zorder=3
            )
            
        # Plot the Threshold as an 'x'
        if 'Yes' in medians and 'No' in medians:
            midpoint = (medians['Yes'] + medians['No']) / 2
            plt.scatter(
                [i], 
                [midpoint], 
                marker='x', 
                color='purple', 
                s=150, 
                linewidths=3, 
                zorder=5,
                label='Threshold'
            )

    plt.title('HRV Levels by Subject: Threshold & Distribution', fontsize=16, fontweight='bold', pad=20)
    plt.xlabel('Subject ID', fontsize=12, labelpad=10)
    plt.ylabel('HRV (ms)', fontsize=12, labelpad=10)
    
    # Set x-ticks to subject names
    plt.xticks(range(len(subjects)), subjects)
    
    # Grid and styling
    plt.grid(axis='y', linestyle='--', alpha=0.7)
    
    # Custom Legend for Mean/Median/Midpoint
    from matplotlib.lines import Line2D
    custom_lines = [
        Line2D([0], [0], color='#e67e22', lw=4, alpha=0.4),
        Line2D([0], [0], color='#2ecc71', lw=4, alpha=0.4),
        Line2D([0], [0], color='black', lw=2),
        Line2D([0], [0], color='blue', lw=2, ls='--'),
        Line2D([0], [0], marker='x', color='purple', lw=0, markersize=10, markeredgewidth=2)
    ]
    plt.legend(
        custom_lines, 
        ['Stress (Yes)', 'Not Stressed (No)', 'Median', 'Mean (---)', 'Threshold (x)'],
        title='Legend', bbox_to_anchor=(1.02, 1), loc='upper left'
    )
    
    plt.tight_layout()
    
    output_png = 'hrv_stress_plot.png'
    plt.savefig(output_png, dpi=300)
    print(f"Plot saved successfully as {output_png}")
    
    # Attempt to show the plot (might not work in all environments, but good for local)
    try:
        plt.show()
    except Exception:
        print("Note: Could not open window to show plot. Image saved to file.")

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        create_hrv_plot(sys.argv[1])
    else:
        print("Usage: python stress_plot.py <path_to_csv>")
