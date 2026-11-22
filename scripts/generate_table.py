import matplotlib.pyplot as plt
import pandas as pd

# Set up clean, publication-ready styling configurations
plt.rcParams['font.family'] = 'sans-serif'
plt.rcParams['font.sans-serif'] = ['DejaVu Sans', 'Arial', 'Helvetica']

# Construct the structured protocol baseline coordinates matrix
data = {
    "Physiological / Psychometric Variable": [
        "Energy Availability (EA)", 
        "Resting Cardiac RMSSD", 
        "Gastrointestinal Tolerance (VAS)", 
        "EDE-Q Global Score", 
        "Target Sample Size (N)", 
        "Power Calculation Parameters"
    ],
    "Expected Baseline Range\n(Suppressed State)": [
        "< 30.0 kcal/kg FFM/day", 
        "Individual baseline", 
        "Elevated (symptomatic)", 
        "< 4.0 (Active enrollment gate)", 
        "n = 30 (Experimental Cohort)", 
        "Effect size (Cohen's d) = 0.75"
    ],
    "Target Clinical Threshold /\nIntervention Goal": [
        "≥ 45.0 kcal/kg FFM/day", 
        "≥ 25% elevation above baseline", 
        "Significant longitudinal reduction", 
        "Maintained below pathology line", 
        "n = 30 (Active Control Cohort)", 
        "Power = 0.80, Alpha = 0.05"
    ],
    "Proposed Statistical\nEvaluation Method": [
        "Linear Mixed-Effects Model Covariate", 
        "Autonomic Decision Gating Logic", 
        "Repeated Measures Linear Contrasts", 
        "Baseline Exclusion Stratification", 
        "Power-Calculated Pool (N = 60)", 
        "A priori sample size justification"
    ]
}

df = pd.DataFrame(data)

# Initialize canvas geometry with premium DPI scaling configurations
fig, ax = plt.subplots(figsize=(14, 5.5), dpi=300)
ax.axis('off')

# Render the formal matrix structure array
table = ax.table(
    cellText=df.values, 
    colLabels=df.columns, 
    cellLoc='left', 
    loc='center'
)

# Apply correct API calls for font sizing and cell formatting scaling
table.auto_set_font_size(False)
table.set_fontsize(10.5)
table.scale(1.2, 2.4)

# Set professional color palette settings
header_bg = '#1e293b'  # Slate Deep Dark Blue
header_text = '#ffffff'
row_even_bg = '#f8fafc'
row_odd_bg = '#ffffff'
border_color = '#cbd5e1'

for (row, col), cell in table.get_celld().items():
    cell.set_edgecolor(border_color)
    cell.set_linewidth(0.6)
    
    if row == 0:
        # Header configurations
        cell.set_text_props(color=header_text, weight='bold', wrap=True)
        cell.set_facecolor(header_bg)
    else:
        # Alternating background configurations
        cell.set_text_props(color='#0f172a', wrap=True)
        if row % 2 == 0:
            cell.set_facecolor(row_even_bg)
        else:
            cell.set_facecolor(row_odd_bg)
            
        # Bold variable target indexes in column 0 for clean legibility 
        if col == 0:
            cell.set_text_props(weight='bold', color='#1e293b')

# Final graphic compilation compilation pipeline
plt.tight_layout()
plt.savefig('REDs_Target_Clinical_Coordinates_Table.png', bbox_inches='tight', dpi=300)
print("SUCCESS: Target table successfully rendered and saved as 'REDs_Target_Clinical_Coordinates_Table.png'")
