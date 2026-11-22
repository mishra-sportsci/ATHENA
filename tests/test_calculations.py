import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tasks import (
    _calculate_readiness,
    _calculate_daily_load,
    _calculate_recovery_stress_balance,
    _calculate_iron_risk,
)

def test_readiness_perfect():
    result = _calculate_readiness(7, 1, 1, 1, 9)
    assert result in (99, 100)

def test_readiness_poor():
    result = _calculate_readiness(1, 7, 7, 7, 4)
    assert result < 30

def test_readiness_mid():
    result = _calculate_readiness(4, 4, 4, 4, 7)
    assert 45 <= result <= 65

def test_daily_load_basic():
    result = _calculate_daily_load(5, 60)
    assert result == 300.0

def test_daily_load_amputation_lower():
    result = _calculate_daily_load(5, 60, "amputation_lower")
    assert result == 255.0

def test_recovery_stress_balance_positive():
    result = _calculate_recovery_stress_balance(7, 9, 1, 1, 1, "neutral")
    assert result["status"] == "POSITIVE_BALANCE"

def test_iron_risk_female_heavy():
    result = _calculate_iron_risk("Female", "heavy", "vegetarian", 20, 11, "run")
    assert result["risk"] == "HIGH"

def test_iron_risk_male_low():
    result = _calculate_iron_risk("Male", "none", "mixed", 80, 15, "swim")
    assert result["risk"] == "LOW"

def test_aes_256_gcm_encryption_roundtrip():
    from tasks import encrypt_pii, decrypt_pii
    secret_note = "Athlete bilateral knee effusion, cleared for low-impact cycling."
    ciphertext = encrypt_pii(secret_note)
    assert ciphertext != secret_note
    decrypted = decrypt_pii(ciphertext)
    assert decrypted == secret_note

def test_rbac_roles_matrix():
    from auth import check_permission
    doc = {"sub": "dr_smith", "role": "physician"}
    assert check_permission(doc, "clinical_notes") is True
    assert check_permission(doc, "read") is True

    ath = {"sub": "ATH-001", "role": "athlete"}
    assert check_permission(ath, "clinical_notes") is False
    assert check_permission(ath, "read", target_user_id="ATH-001") is True
    assert check_permission(ath, "read", target_user_id="ATH-002") is False

print("All core calculation tests passed.")
