# A.T.H.E.N.A. (Prototype) — AI-Assisted Sports Science Analytics Console

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Commercial License](https://img.shields.io/badge/Commercial%20License-Available-orange.svg)](COMMERCIAL.md)
[![AI-Assisted](https://img.shields.io/badge/Development-AI--Assisted%20Orchestration-purple.svg)](AI_DISCLOSURE.md)
[![Validation](https://img.shields.io/badge/Scientific%20Math-Manually%20Validated-success.svg)](VALIDATION.md)
[![CLA Required](https://img.shields.io/badge/Contributions-CLA%20Required-teal.svg)](CLA.md)
[![Python: 3.12+](https://img.shields.io/badge/Python-3.12%2B-blue.svg)](https://www.python.org/)
[![R: 4.4+](https://img.shields.io/badge/R-4.4%2B-blue.svg)](https://www.r-project.org/)

---

## Author & Project Role

- **Author:** Abhishek Mishra ([@mishra-sportsci](https://github.com/mishra-sportsci))
- **Role:** Pre-PhD Sports Science Researcher
- **Domain Focus:** Exercise Physiology, Clinical Sports Biomechanics, Athlete Workload Management, and Relative Energy Deficiency in Sport (RED-S).
- **Project Contribution:** Domain logic definition (IOC RED-S Consensus, Acute:Chronic Workload Ratio, Blood Lactate Kinetics), prompt engineering, AI orchestration, and manual mathematical validation.

---

## Project Context: What This Is vs. What This Is NOT

### What this IS:
- An **exploratory academic prototype** demonstrating how domain knowledge in clinical sports science can be translated into an interactive computational interface using modern AI tools.
- A proof-of-concept for integrating evidence-based sports science algorithms (IOC RED-S Consensus, ACWR, metabolic turnpoints) into a unified telemetry dashboard.
- A transparent demonstration of **AI orchestration** guided by a domain specialist.

### What this is NOT:
- **NOT a production-ready clinical medical tool** or certified Medical Device Software (SaMD).
- **NOT a demonstration of independent, professional software engineering capability** (all code was generated using free AI coding assistants; see [AI_DISCLOSURE.md](AI_DISCLOSURE.md)).
- **NOT intended for direct diagnostic or medical decision-making** without qualified clinical supervision.

---

## Key Governance & Transparency Documents

To maintain full academic and ethical integrity, please review the following foundational documents:

- 📄 **[AI_DISCLOSURE.md](AI_DISCLOSURE.md)** — Full disclosure of AI assistant usage, generation methodology, and "as-is" prototype disclaimer.
- 📐 **[VALIDATION.md](VALIDATION.md)** — Manual mathematical validation of AI-generated formulas against peer-reviewed sports science literature (including step-by-step Energy Availability and ACWR calculations).
- 💼 **[COMMERCIAL.md](COMMERCIAL.md)** — Dual-licensing explanation: Free under AGPL-3.0; Commercial licenses available for proprietary or closed-source use.
- 📝 **[CLA.md](CLA.md)** — Contributor License Agreement granting perpetual copyright licenses required for dual-licensing maintenance.
- 🤖 **[AI_POLICY.md](AI_POLICY.md)** — Contributor policy governing the disclosure and validation of AI-generated contributions.

---

## Dual-Licensing Architecture

A.T.H.E.N.A. is distributed under a **dual-licensing model**:

1. **Open Source (GNU AGPLv3):**  
   Freely available for researchers, educators, and the open-source community under the **GNU Affero General Public License v3.0**. Under this license, any derivative works, modifications, or network deployments (such as SaaS) must have their complete source code made publicly available under AGPLv3. See [LICENSE](LICENSE).

2. **Commercial License:**  
   If your organization intends to incorporate this software or its algorithms into proprietary, closed-source applications or enterprise platforms without being bound by the copyleft provisions of the AGPLv3, a commercial license is required.  
   **Contact:** [abhishek.mishra.sportsci@gmail.com](mailto:abhishek.mishra.sportsci@gmail.com).

---

## Core Scientific Formulations Implemented

### 1. Energy Availability (IOC RED-S Consensus)
Evaluates metabolic energy remaining after training demands relative to Fat-Free Mass (Mountjoy et al., 2018, 2023):

$$\text{EA} = \frac{\text{Energy Intake (EI)} - \text{Exercise Energy Expenditure (EEE)}}{\text{Fat-Free Mass (FFM)}} \quad [\text{kcal} \cdot \text{kg FFM}^{-1} \cdot \text{day}^{-1}]$$

- **Optimal EA:** $\ge 45 \text{ kcal} \cdot \text{kg FFM}^{-1} \cdot \text{day}^{-1}$
- **Subclinical Caution:** $30 \le \text{EA} < 45 \text{ kcal} \cdot \text{kg FFM}^{-1} \cdot \text{day}^{-1}$
- **Clinical Low EA (High Risk):** $< 30 \text{ kcal} \cdot \text{kg FFM}^{-1} \cdot \text{day}^{-1}$

*Detailed manual step-by-step verification is documented in [VALIDATION.md](VALIDATION.md).*

### 2. Acute:Chronic Workload Ratio (ACWR)
Monitors workload progression using rolling and exponentially weighted moving averages (Gabbett, 2016; Hulin et al., 2016):

$$\text{ACWR} = \frac{\text{Acute Workload (7-Day Rolling)}}{\text{Chronic Workload (28-Day Rolling)}}$$

- **Under-preparedness:** $< 0.8$
- **Adaptation Sweet Spot:** $0.8 \le \text{ACWR} \le 1.3$
- **Workload Spike (Elevated Risk):** $> 1.5$

### 3. Dual-Threshold Blood Lactate Kinetics
Identifies aerobic turnpoint (LT1, typically $\sim 2.0 \text{ mmol/L}$) and anaerobic turnpoint (LT2 / OBLA, typically $\sim 4.0 \text{ mmol/L}$) using B-spline interpolation across incremental step tests (Faude et al., 2009).

---

## Running the Prototype

### Prerequisites
- **Python:** 3.12+ ([python.org](https://www.python.org/downloads/))
- **R:** 4.4+ ([CRAN](https://cran.r-project.org/))

### Option A: Windows Automated Setup (1-Click)
Clone the repository and run the setup script in Command Prompt or PowerShell:
```cmd
deploy\windows\setup_windows.bat
deploy\windows\launch_shiny.bat
```

### Option B: Linux / macOS
```bash
# 1. Install Python dependencies
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 2. Run Master FastAPI Web Service
./athena.sh

# 3. Or launch R Shiny Clinical Telemetry Hub directly
./run_shiny.sh
```

### Active Endpoints
- **Master Web Application:** `http://localhost:8000`
- **R Shiny Clinical Console:** `http://localhost:3838`
- **OpenAPI / Swagger Documentation:** `http://localhost:8000/api/docs`

---

## Contributing

Community contributions, code reviews, and scientific validations are welcome! Because this repository operates under a dual-licensing model, all contributors must:
1. Review and agree to the [Contributor License Agreement (CLA)](CLA.md).
2. Adhere to the [AI Contribution Policy](AI_POLICY.md) by disclosing any AI-assisted code.

To contribute:
1. Fork the repository.
2. Create a topic branch: `git checkout -b feature/scientific-refinement`.
3. Submit a Pull Request with the CLA agreement noted in the description.

---

## Citation & Contact

If this prototype or its domain formulations assist your research or development, please cite this repository:

```bibtex
@misc{mishra2026athena,
  author = {Mishra, Abhishek},
  title = {{A.T.H.E.N.A.: AI-Assisted Sports Science Analytics Console (Prototype)}},
  year = {2026},
  publisher = {GitHub},
  howpublished = {\url{https://github.com/mishra-sportsci/ATHENA-v0.1}}
}
```

- **Project Lead:** Abhishek Mishra
- **Email:** [abhishek.mishra.sportsci@gmail.com](mailto:abhishek.mishra.sportsci@gmail.com)
- **Institution:** Sports Science & Exercise Physiology Research
