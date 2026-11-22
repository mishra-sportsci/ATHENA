# Contributing to A.T.H.E.N.A.

Thank you for your interest in contributing to the **A.T.H.E.N.A.** Clinical Intelligence Workspace. We welcome contributions from sports scientists, exercise physiologists, biostatisticians, and software engineers.

---

## 1. Scientific & Methodological Standards

Any proposed modifications to physiological algorithms, workload calculations, or clinical screening criteria must adhere to **Peer-Reviewed Scientific & Clinical Standards**:

1. **Evidence-Based Mechanisms:** Algorithms must cite empirical consensus statements (e.g., IOC Consensus Statements, ACSM guidelines, BASES criteria, or FIFA Medical Protocols).
2. **Zero Fabrication & Zero Magic Numbers:** Constants must be derived from peer-reviewed literature and documented with inline citations (e.g., Harris-Benedict/Cunningham RMR coefficients, EWMA decay factors $\lambda = 2 / (N + 1)$).
3. **Validation Test Suite:** Algorithmic modifications must include automated unit tests under `tests/` validating edge cases, missing data imputation, and boundary conditions.

---

## 2. Development Workflow

1. **Fork & Branch:** Create a feature branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. **Virtual Environment Setup:**
   ```bash
   python3 -m venv athena_env
   source athena_env/bin/activate
   pip install -r requirements.txt
   ```
3. **Pre-Commit Sanitization Checks:**
   * Verify no database files (`*.db`), keys (`.athena*`), or personal logs are staged.
   * Run automated unit tests:
     ```bash
     python3 -m unittest discover -s tests
     ```
4. **Pull Request Protocol:**
   * Provide a concise explanation of the clinical or technical motivation.
   * Cite relevant physiological literature where applicable.
