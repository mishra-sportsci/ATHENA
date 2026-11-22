"""ATHENA API Test Suite — Run with: pytest tests/test_api.py -v"""
import pytest
from fastapi.testclient import TestClient
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from athena_api import app

client = TestClient(app)
API_KEY = os.getenv("ATHENA_API_KEY", "test-key-change-me")
HEADERS = {"X-API-Key": API_KEY}

class TestSystemHealth:
    def test_health_endpoint(self):
        response = client.get("/api/health")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] in ("healthy", "degraded")
        assert data["service"] == "A.T.H.E.N.A. API"
    
    def test_system_profile(self):
        response = client.get("/api/system/profile")
        assert response.status_code == 200
        data = response.json()
        assert "capabilities" in data
        assert "operating_mode" in data["capabilities"]
    
    def test_methods_endpoint(self):
        response = client.get("/api/methods")
        assert response.status_code == 200
        data = response.json()
        assert "algorithms" in data
        assert "acwr_uncoupled" in data["algorithms"]

class TestDataSync:
    def test_sync_data_valid(self):
        payload = {
            "user_id": "TEST_ATHLETE_001",
            "timestamp": "2026-06-08T10:00:00",
            "gender": "Female",
            "duration_minutes": 60,
            "rpe": 5,
            "sleep_hours": 7.5,
            "sleep_quality": 4,
            "stress": 3,
            "fatigue": 3,
            "muscle_soreness": 2,
            "mood": "neutral",
            "cycle_phase": "follicular",
            "calories": 2200,
            "ffm": 52.0
        }
        response = client.post("/sync-data", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert data["status"] in ("queued", "processed")
        assert "task_id" in data
    
    def test_sync_data_invalid_gender(self):
        payload = {
            "user_id": "TEST_ATHLETE_002",
            "timestamp": "2026-06-08T10:00:00",
            "gender": "Invalid",
            "duration_minutes": 60,
            "rpe": 5,
            "sleep_hours": 7.5,
            "sleep_quality": 4,
            "stress": 3,
            "fatigue": 3,
            "muscle_soreness": 2
        }
        response = client.post("/sync-data", json=payload)
        assert response.status_code == 422
    
    def test_sync_data_invalid_rpe(self):
        payload = {
            "user_id": "TEST_ATHLETE_003",
            "timestamp": "2026-06-08T10:00:00",
            "gender": "Male",
            "duration_minutes": 60,
            "rpe": 15,
            "sleep_hours": 7.5,
            "sleep_quality": 4,
            "stress": 3,
            "fatigue": 3,
            "muscle_soreness": 2
        }
        response = client.post("/sync-data", json=payload)
        assert response.status_code == 422

class TestAnalyticsEndpoints:
    def test_session_plan_no_data(self):
        response = client.get("/api/session-plan/NONEXISTENT_USER")
        assert response.status_code in [200, 404]
    
    def test_recovery_protocol_no_data(self):
        response = client.get("/api/v1/recovery/protocol/NONEXISTENT_USER")
        assert response.status_code in [200, 404]
    
    def test_nutrition_plan_no_data(self):
        response = client.get("/api/nutrition-plan/NONEXISTENT_USER")
        assert response.status_code in [200, 404]

class TestFemaleAthleteEndpoints:
    def test_cycle_prediction_no_data(self):
        response = client.get("/api/cycle-prediction/TEST_FEMALE_001?cycle_length=28&period_length=5")
        assert response.status_code in [200, 404]
    
    def test_iron_risk_no_data(self):
        response = client.get("/api/iron-risk/TEST_FEMALE_001")
        assert response.status_code in [200, 404]

class TestFieldTests:
    def test_rockport_vo2max(self):
        payload = {"gender": "male", "weight_kg": 70, "age_years": 25, "walk_time_min": 15, "heart_rate_bpm": 130}
        response = client.post("/api/field-tests/rockport", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert "estimated_vo2max_ml_kg_min" in data
        assert data["estimated_vo2max_ml_kg_min"] > 20
    
    def test_cooper_vo2max(self):
        payload = {"distance_m": 2400}
        response = client.post("/api/field-tests/cooper", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert data["estimated_vo2max_ml_kg_min"] > 20

class TestStatistics:
    def test_effect_size(self):
        payload = {"mean_pre": 50, "mean_post": 55, "sd_pre": 10, "sample_size": 20}
        response = client.post("/api/statistics/effect-size", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert data["cohens_d"] == 0.5
    
    def test_reliability(self):
        payload = {"trial_1": [10, 11, 12, 10, 11], "trial_2": [10.5, 10.5, 12.5, 9.5, 11]}
        response = client.post("/api/statistics/reliability", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert "typical_error_of_measurement" in data

class TestACSMCompliance:
    def test_acsm_screening_low_risk(self):
        payload = {"responses": {"q1": False, "q2": False, "q3": False, "q4": False, "q5": False, "q6": False, "q7": False}}
        response = client.post("/api/acsm-screening", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert data["clearance"] == "NOT_REQUIRED"
    
    def test_acsm_screening_critical(self):
        payload = {"responses": {"q1": False, "q2": False, "q3": True, "q4": True, "q5": False, "q6": False, "q7": False}}
        response = client.post("/api/acsm-screening", json=payload)
        assert response.status_code == 200
        data = response.json()
        assert data["clearance"] == "REQUIRED"

if __name__ == "__main__":
    pytest.main([__file__, "-v"])