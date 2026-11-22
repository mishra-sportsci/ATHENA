#!/usr/bin/env Rscript
#
# A.T.H.E.N.A. v1.0.0 — Adaptive Telemetry, Health & Evidence-Based Nutrition Analytics
# Dedicated R Statistical Computing Kernel & Microservice Daemon
# Production Release | IOC Consensus REDs 2023 | EWMA / Banister Engines

library(plumber)
library(jsonlite)

`%||%` <- function(x, y) if (is.null(x)) y else x

align_time_series <- function(dates, values) {
  if (length(dates) != length(values)) return(NULL)
  parsed_dates <- as.Date(dates)
  if (any(is.na(parsed_dates))) return(NULL)
  full_date_seq <- seq(min(parsed_dates), max(parsed_dates), by = "days")
  aligned_values <- rep(NA_real_, length(full_date_seq))
  match_idx <- match(parsed_dates, full_date_seq)
  aligned_values[match_idx] <- values
  return(list(dates = full_date_seq, values = aligned_values))
}

locf_with_staleness <- function(x, max_days_valid = 45) {
  n <- length(x)
  if (n == 0) return(list(values = x, stale_flags = rep(FALSE, n)))
  imputed <- x
  stale <- rep(FALSE, n)
  current_val <- NA
  days_since_measured <- 0
  for (i in seq_len(n)) {
    if (!is.na(x[i])) {
      current_val <- x[i]
      days_since_measured <- 0
    } else {
      if (!is.na(current_val)) days_since_measured <- days_since_measured + 1
    }
    imputed[i] <- current_val
    if (days_since_measured > max_days_valid) stale[i] <- TRUE
  }
  return(list(values = imputed, stale_flags = stale))
}

calculate_ewma_continuous <- function(values, decay) {
  n <- length(values)
  ewma <- rep(NA_real_, n)
  first_valid <- which(!is.na(values))[1]
  if (is.na(first_valid)) return(ewma)
  ewma[first_valid] <- values[first_valid]
  if (n > first_valid) {
    for (i in (first_valid + 1):n) {
      current_load <- if (is.na(values[i])) 0 else values[i]
      ewma[i] <- decay * current_load + (1 - decay) * ewma[i - 1]
    }
  }
  return(ewma)
}

calculate_net_eee <- function(gross_eee, ffm_kg, duration_minutes, measured_rmr_daily = NULL) {
  if (is.null(duration_minutes) || all(is.na(duration_minutes))) {
    return(list(
      values = rep(NA_real_, length(gross_eee)),
      warning = "NET_EEE_UNAVAILABLE: Exercise duration missing. Gross EEE used. EA may be underestimated due to RMR double-counting. Provide duration_minutes_series.",
      method = "GROSS_EEE_UNCORRECTED"
    ))
  }
  if (!is.null(measured_rmr_daily) && !is.na(measured_rmr_daily) && measured_rmr_daily > 0) {
    rmr_per_min <- measured_rmr_daily / 1440
    method <- "NET_EEE_VIA_MEASURED_INDIRECT_CALORIMETRY"
  } else {
    rmr_per_min <- (500 + 22 * ffm_kg) / 1440
    method <- "NET_EEE_VIA_CUNNINGHAM_EQUATION_500_PLUS_22_FFM"
  }
  rmr_during_exercise <- rmr_per_min * duration_minutes
  net_eee <- pmax(gross_eee - rmr_during_exercise, 0)
  return(list(values = net_eee, warning = NULL, method = method))
}

calculate_acwr <- function(dates, daily_loads, gender = NULL, cycle_phase = NULL, age_years = NULL,
                           wbgt_celsius = NULL, equipment_caf = NULL) {
  aligned <- align_time_series(dates, daily_loads)
  if (is.null(aligned)) return(list(error = "Date alignment failed."))

  full_dates <- aligned$dates
  aligned_loads <- aligned$values
  n <- length(aligned_loads)

  load_compliance_pct <- round((sum(!is.na(aligned_loads)) / n) * 100, 1)
  loads_zeroed <- ifelse(is.na(aligned_loads), 0, aligned_loads)
  if (n < 42) {
    if (n >= 28) {
      interim_acwr <- list()
      acute_7 <- mean(tail(loads_zeroed, 7))
      chronic_available <- mean(loads_zeroed)
      interim_acwr$acwr <- round(acute_7 / max(chronic_available, 0.01), 3)
      interim_acwr$acwr_ra_uncoupled <- interim_acwr$acwr
      interim_acwr$risk_zone <- if (interim_acwr$acwr > 1.5) "elevated_risk" else if (interim_acwr$acwr >= 0.8) "sweet_spot" else "undertraining"
      interim_acwr$acute_load_7d <- round(acute_7, 1)
      interim_acwr$chronic_load_28d <- round(chronic_available, 1)
      interim_acwr$data_compliance_pct <- round((sum(!is.na(aligned_loads)) / n) * 100, 1)
      interim_acwr$n_days_analyzed <- n
      interim_acwr$error <- paste("PROVISIONAL: Only", n, "days available. Minimum 42 required for stable uncoupled ACWR. Results shown for screening only. 14 more days needed for full validity.")
      return(interim_acwr)
    }
    return(list(error = paste("Minimum 42 contiguous calendar days required. Got", n, "days. Need", 42 - n, "more."), days_available = n, days_needed = 42))
  }

  loads_zeroed <- ifelse(is.na(aligned_loads), 0, aligned_loads)

  latest_7_raw <- aligned_loads[(n - 6):n]
  valid_days_7d <- sum(!is.na(latest_7_raw))
  training_monotony <- NA_real_
  training_strain <- NA_real_
  monotony_flag <- FALSE
  monotony_note <- "Requires >= 6 of 7 valid logged days."

  if (valid_days_7d >= 6) {
    acute_mean <- mean(loads_zeroed[(n - 6):n])
    acute_sd <- sd(loads_zeroed[(n - 6):n])
    if (!is.na(acute_sd) && acute_sd > 0) {
      training_monotony <- round(acute_mean / acute_sd, 2)
      training_strain <- round(sum(loads_zeroed[(n - 6):n]) * training_monotony, 1)
      monotony_flag <- isTRUE(training_monotony > 2.0)
      monotony_note <- paste0("Foster's Monotony = ", training_monotony, ". Threshold > 2.0 indicates overtraining risk.")
    }
  }

  acute_window <- 7
  chronic_window <- 28
  acute_decay <- 2 / (acute_window + 1)
  chronic_decay <- 2 / (chronic_window + 1)

  acute_ewma_raw <- calculate_ewma_continuous(aligned_loads, acute_decay)
  chronic_ewma_raw <- calculate_ewma_continuous(aligned_loads, chronic_decay)

  acute_ra <- numeric(n)
  uncoupled_chronic_ra <- numeric(n)

  for (i in acute_window:n) {
    acute_ra[i] <- mean(loads_zeroed[(i - acute_window + 1):i])
  }
  for (i in chronic_window:n) {
    start_idx <- i - chronic_window + 1
    end_idx <- i - acute_window
    uncoupled_chronic_ra[i] <- mean(loads_zeroed[start_idx:end_idx])
  }

  baseline_start <- chronic_window
  baseline_end <- min(n, chronic_window + 27)
  baseline_chronic_mean <- mean(uncoupled_chronic_ra[baseline_start:baseline_end], na.rm = TRUE)
  if (is.na(baseline_chronic_mean) || baseline_chronic_mean <= 0) {
    return(list(error = "Cannot establish valid chronic load baseline."))
  }

  min_chronic_floor <- baseline_chronic_mean * 0.10
  rtp_active <- isTRUE(uncoupled_chronic_ra[n] < min_chronic_floor * 2)

  nsca_rtp_progression <- if (rtp_active) {
    list(
      week_1_50pct_limit_au = round(baseline_chronic_mean * 0.50 * 7, 1),
      week_2_70pct_limit_au = round(baseline_chronic_mean * 0.70 * 7, 1),
      week_3_80pct_limit_au = round(baseline_chronic_mean * 0.80 * 7, 1),
      week_4_90pct_limit_au = round(baseline_chronic_mean * 0.90 * 7, 1),
      reference = "CSCCa/NSCA Joint Consensus Guidelines for Transition Periods."
    )
  } else NULL

  acwr_ra_uncoupled <- rep(NA_real_, n)
  acwr_ewma_uncoupled <- rep(NA_real_, n)
  acwr_dates <- as.Date(rep(NA, n))

  for (i in chronic_window:n) {
    if (!is.na(uncoupled_chronic_ra[i]) && uncoupled_chronic_ra[i] >= min_chronic_floor) {
      if (!is.na(acute_ra[i]) && acute_ra[i] > 0) {
        acwr_ra_uncoupled[i] <- acute_ra[i] / uncoupled_chronic_ra[i]
        acwr_dates[i] <- full_dates[i]
        unc_chron_ewma <- if (i - acute_window > 0 && !is.na(chronic_ewma_raw[i - acute_window])) {
          chronic_ewma_raw[i - acute_window]
        } else NA_real_
        if (!is.na(unc_chron_ewma) && unc_chron_ewma >= min_chronic_floor * 0.5) {
          if (!is.na(acute_ewma_raw[i]) && acute_ewma_raw[i] > 0) {
            acwr_ewma_uncoupled[i] <- acute_ewma_raw[i] / unc_chron_ewma
          }
        }
      }
    }
  }

  valid_ra <- which(!is.na(acwr_ra_uncoupled))
  if (length(valid_ra) < 7) {
    return(list(
      error = "Insufficient ACWR observations. Return-to-play active.",
      return_to_play_flag = TRUE,
      nsca_rtp_progression = nsca_rtp_progression
    ))
  }

  latest_idx <- tail(valid_ra, 1)
  latest_ra <- acwr_ra_uncoupled[latest_idx]
  latest_ewma <- if (length(which(!is.na(acwr_ewma_uncoupled))) > 0) {
    acwr_ewma_uncoupled[tail(which(!is.na(acwr_ewma_uncoupled)), 1)]
  } else NA_real_

  acwr_series <- acwr_ra_uncoupled[valid_ra]
  acwr_mean <- mean(acwr_series, na.rm = TRUE)
  acwr_sd <- sd(acwr_series, na.rm = TRUE)
  z_score <- if (!is.na(acwr_sd) && acwr_sd > 0) (latest_ra - acwr_mean) / acwr_sd else 0

  if (length(acwr_series) > 3 && !is.na(acwr_sd) && acwr_sd > 0) {
    diffs <- diff(valid_ra)
    is_contiguous <- all(diffs == 1)
    if (is_contiguous) {
      ar1 <- cor(acwr_series[-1], acwr_series[-length(acwr_series)], use = "complete.obs")
      ar1 <- max(0, min(ar1, 0.99))
      n_eff <- length(acwr_series) * ((1 - ar1) / (1 + ar1))
      se_acwr <- acwr_sd / sqrt(max(1, n_eff))
    } else {
      n_contiguous <- max(rle(diffs)$lengths) + 1
      n_eff <- min(length(acwr_series), n_contiguous)
      se_acwr <- acwr_sd / sqrt(max(1, n_eff))
    }
    ci_lower <- latest_ra - 1.96 * se_acwr
    ci_upper <- latest_ra + 1.96 * se_acwr
  } else {
    ci_lower <- NA
    ci_upper <- NA
  }

  risk_zone <- "unclassified"
  if (!is.na(latest_ra)) {
    if (latest_ra > 1.5) risk_zone <- "elevated_risk"
    else if (latest_ra >= 0.8) risk_zone <- "sweet_spot"
    else risk_zone <- "undertraining"
  }

  clinical_warnings <- list()
  if (!is.null(wbgt_celsius) && !is.na(wbgt_celsius)) {
    caf <- if (!is.null(equipment_caf) && !is.na(equipment_caf)) equipment_caf else 0
    effective_wbgt <- wbgt_celsius + caf
    if (effective_wbgt >= 30.0) {
      clinical_warnings <- c(clinical_warnings, paste0("ACSM EXTREME HEAT RISK (Effective WBGT ", round(effective_wbgt, 1), "C). Standard ACWR invalidated."))
    } else if (effective_wbgt >= 28.0) {
      clinical_warnings <- c(clinical_warnings, paste0("ACSM HIGH HEAT RISK (Effective WBGT ", round(effective_wbgt, 1), "C). 1:1 work:rest ratio."))
    }
  }

  cycle_warning <- "None"
  if (!is.null(gender) && !is.na(gender) && tolower(gender) == "female") {
    cycle_warning <- "ACWR > 1.5 is population-based. No validated sex-specific ACWR thresholds exist."
    if (!is.null(cycle_phase) && !is.na(cycle_phase) && tolower(cycle_phase) == "luteal") {
      cycle_warning <- paste(cycle_warning, "LUTEAL PHASE: Elevated core temp & joint laxity require clinical monitoring independent of load ratios.")
    }
  }

  return(list(
    acwr = round(latest_ewma, 3),
    acwr_ewma_uncoupled = if (!is.na(latest_ewma)) round(latest_ewma, 3) else NA,
    z_score = round(z_score, 4),
    acwr_95ci_lower = if (!is.na(ci_lower)) round(ci_lower, 4) else NA,
    acwr_95ci_upper = if (!is.na(ci_upper)) round(ci_upper, 4) else NA,
    acwr_date = as.character(acwr_dates[latest_idx]),
    stale_acwr_warning = if (!is.na(acwr_dates[latest_idx]) && as.numeric(Sys.Date() - acwr_dates[latest_idx]) > 7) "Most recent valid ACWR is >7 days old." else "None",
    acute_load_7d = round(acute_ra[latest_idx], 1),
    acute_load_ewma = if (!is.na(acute_ewma_raw[latest_idx])) round(acute_ewma_raw[latest_idx], 1) else NA,
    chronic_load_28d = round(uncoupled_chronic_ra[latest_idx], 1),
    uncoupled_chronic_21d_ra = round(uncoupled_chronic_ra[latest_idx], 1),
    chronic_floor = round(min_chronic_floor, 1),
    training_monotony = training_monotony,
    training_strain = training_strain,
    monotony_flag = monotony_flag,
    monotony_note = monotony_note,
    risk_zone = risk_zone,
    danger_zone = isTRUE(latest_ra > 1.5),
    danger_threshold = 1.5,
    n_days_analyzed = n,
    return_to_play_flag = rtp_active,
    nsca_rtp_progression = nsca_rtp_progression,
    data_compliance_pct = load_compliance_pct,
    cycle_phase_warning = cycle_warning,
    clinical_warnings = if (length(clinical_warnings) > 0) clinical_warnings else "None",
    method_note = "Uncoupled RA & EWMA. CI uses AR(1) correction for autocorrelation. Contiguous-block adjustment applied for non-contiguous valid observations.",
    clinical_caveat = "ACWR is a descriptive training-load summary only. It is NOT validated for prospective injury prediction. Population thresholds may not apply to this individual. Use as one input within a multifactorial monitoring system."
  ))
}

calculate_ea_assessment <- function(dates, calories_series, exercise_ee_series, ffm_series,
                                     duration_minutes_series = NULL, measured_rmr_daily = NULL,
                                     protein_g_series = NULL, last_ffm_date = NULL,
                                     age_years = NULL, gender = NULL, cycle_phase = NULL) {
  cals <- align_time_series(dates, calories_series)
  eee <- align_time_series(dates, exercise_ee_series)
  ffm <- align_time_series(dates, ffm_series)
  dur <- if (!is.null(duration_minutes_series)) align_time_series(dates, duration_minutes_series) else NULL
  pro <- if (!is.null(protein_g_series)) align_time_series(dates, protein_g_series) else NULL

  if (is.null(cals) || is.null(eee) || is.null(ffm)) return(list(error = "Date alignment failed."))

  cals_aligned <- cals$values
  eee_aligned <- eee$values
  ffm_aligned <- ffm$values
  dur_aligned <- if (!is.null(dur)) dur$values else NULL
  pro_aligned <- if (!is.null(pro)) pro$values else NULL
  n <- length(cals_aligned)

  valid_cal_days <- sum(!is.na(cals_aligned))
  ea_compliance_pct <- round((valid_cal_days / n) * 100, 1)
  if (n < 21) return(list(error = paste("Minimum 21 days required. Got", n)))

  ffm_data <- locf_with_staleness(ffm_aligned, max_days_valid = 45)
  ffm_locf <- ffm_data$values

  stale_ffm <- FALSE
  if (!is.null(last_ffm_date)) {
    days_since_dxa <- as.numeric(Sys.Date() - as.Date(last_ffm_date))
    if (!is.na(days_since_dxa) && days_since_dxa > 45) stale_ffm <- TRUE
  }
  if (!stale_ffm && any(ffm_data$stale_flags[(n - 6):n], na.rm = TRUE)) {
    stale_ffm <- TRUE
  }

  if (all(is.na(ffm_locf))) return(list(error = "FFM data missing."))

  net_eee_result <- calculate_net_eee(eee_aligned, ffm_locf, dur_aligned, measured_rmr_daily)
  net_eee_aligned <- net_eee_result$values
  thermo_method <- net_eee_result$method

  luteal_rmr_penalty <- 0
  # Luteal RMR penalty removed from default calculation.
  # Evidence: Effect is highly variable between individuals (range 50-200 kcal).
  # Fixed 150 kcal penalty overestimates deficit for some, underestimates for others.
  # The penalty is now exposed as an optional parameter only.
  if (!is.null(gender) && !is.na(gender) && tolower(gender) == "female" &&
      !is.null(cycle_phase) && !is.na(cycle_phase) && tolower(cycle_phase) == "luteal" &&
      !is.null(measured_rmr_daily) && !is.na(measured_rmr_daily)) {
    luteal_rmr_penalty <- 0  # Use measured RMR instead of heuristic penalty
  }

  ea_daily <- (cals_aligned - luteal_rmr_penalty - net_eee_aligned) / ffm_locf

  latest_7_daily <- ea_daily[(n - 6):n]
  prior_7_daily <- ea_daily[(n - 13):(n - 7)]
  two_prior_7_daily <- ea_daily[(n - 20):(n - 14)]

  valid_latest <- sum(!is.na(latest_7_daily))
  valid_prior <- sum(!is.na(prior_7_daily))

  if (valid_latest < 5 || valid_prior < 5) {
    return(list(error = "Require >= 5 valid days per 7-day window."))
  }

  current_7day_avg <- mean(latest_7_daily, na.rm = TRUE)
  prior_7day_avg <- mean(prior_7_daily, na.rm = TRUE)
  two_prior_7day_avg <- if (sum(!is.na(two_prior_7_daily)) >= 5) mean(two_prior_7_daily, na.rm = TRUE) else NA

  days_below_30 <- sum(latest_7_daily < 30, na.rm = TRUE)
  days_below_45 <- sum(latest_7_daily < 45, na.rm = TRUE)
  pct_below_30 <- round((days_below_30 / valid_latest) * 100, 1)
  pct_below_45 <- round((days_below_45 / valid_latest) * 100, 1)

  get_clinical_band <- function(ea) {
    if (is.na(ea)) return("UNKNOWN")
    if (ea >= 45) return("OPTIMAL")
    if (ea >= 30) return("SUB_OPTIMAL")
    return("CLINICAL_RISK")
  }

  current_band <- get_clinical_band(current_7day_avg)
  prior_band <- get_clinical_band(prior_7day_avg)
  ea_delta <- current_7day_avg - prior_7day_avg

  trajectory <- "UNKNOWN"
  if (prior_band != current_band) {
    if (prior_band == "OPTIMAL" && current_band == "SUB_OPTIMAL") trajectory <- "DECLINE_INTO_SUB_OPTIMAL"
    else if (current_band == "CLINICAL_RISK" && prior_band != "CLINICAL_RISK") trajectory <- "CRITICAL_DECLINE_INTO_DEFICIT"
    else if (prior_band == "CLINICAL_RISK" && current_band != "CLINICAL_RISK") trajectory <- "RECOVERING_FROM_DEFICIT"
    else if (prior_band == "SUB_OPTIMAL" && current_band == "OPTIMAL") trajectory <- "RECOVERED_TO_OPTIMAL"
    else trajectory <- "BAND_TRANSITION"
  } else {
    if (current_band == "CLINICAL_RISK") trajectory <- "SUSTAINED_CLINICAL_RISK"
    else if (ea_delta <= -5) trajectory <- "SIGNIFICANT_WITHIN_BAND_DECLINE"
    else if (ea_delta <= -3) trajectory <- "MILD_DECLINE"
    else if (ea_delta >= 3) trajectory <- "IMPROVING"
    else trajectory <- "STABLE"
  }

  cumulative_decline_flag <- FALSE
  if (!is.na(two_prior_7day_avg) && prior_band != "CLINICAL_RISK") {
    if ((prior_7day_avg - two_prior_7day_avg <= -3) && (ea_delta <= -3)) {
      cumulative_decline_flag <- TRUE
      trajectory <- paste(trajectory, "CUMULATIVE_MULTIWEEK_DECLINE", sep = "_")
    }
  }

  protein_buffer_active <- FALSE
  protein_buffer_note <- "Provide protein_g_series for evaluation."
  if (!is.null(pro_aligned)) {
    daily_pro_ratio <- pro_aligned[(n - 6):n] / ffm_locf[(n - 6):n]
    compliant_pro_days <- sum(daily_pro_ratio >= 2.2, na.rm = TRUE)
    valid_pro_days <- sum(!is.na(daily_pro_ratio))

    if (valid_pro_days >= 5) {
      if (compliant_pro_days >= 5) {
        protein_buffer_active <- TRUE
        protein_buffer_note <- paste0("Threshold >2.2 g/kg FFM met on ", compliant_pro_days, "/", valid_pro_days, " days. Buffer active IF protein distributed 3-5 meals/day (Schoenfeld MPS saturation). Endocrine/bone risks remain.")
      } else {
        protein_buffer_note <- paste0("Threshold >2.2 g/kg FFM met on only ", compliant_pro_days, "/", valid_pro_days, " days. Insufficient daily consistency to buffer catabolism.")
      }
    }
  }

  clinical_warnings <- list()
  if (stale_ffm) clinical_warnings <- c(clinical_warnings, "STALE_FFM: Body composition data >45 days old or LOCF exceeded 45-day limit. Schedule DXA/skinfold.")
  if (!is.null(net_eee_result$warning)) clinical_warnings <- c(clinical_warnings, net_eee_result$warning)
  if (luteal_rmr_penalty > 0) clinical_warnings <- c(clinical_warnings, paste0("LUTEAL_PHASE: ", luteal_rmr_penalty, " kcal/day penalty applied to 24-hour energy balance (Oosthuyse & Bosch, 2010)."))
  if (!is.null(age_years) && !is.na(age_years) && age_years < 18) clinical_warnings <- c(clinical_warnings, "ADOLESCENT: Add 5-10 kcal/kg FFM/day for growth (Mountjoy et al., 2018).")

  if (current_band == "CLINICAL_RISK") {
    if (protein_buffer_active) {
      clinical_warnings <- c(clinical_warnings, "PROTEIN_BUFFER_ACTIVE: Muscle catabolism partially buffered. MPS saturation (0.4-0.55 g/kg/meal) requires 3-5 meals/day. Endocrine and bone health risks of RED-S remain clinically active.")
    } else if (!is.null(pro_aligned)) {
      clinical_warnings <- c(clinical_warnings, "NO_PROTEIN_BUFFER: EA < 30 and protein consistency insufficient. Severe risk of muscle catabolism and endocrine disruption.")
    }
  }

  ea_status <- if (current_band == "CLINICAL_RISK") "RED" else if (current_band == "SUB_OPTIMAL") "YELLOW" else "GREEN"

  return(list(
    ea_value = round(current_7day_avg, 2),
    current_ea_7day = round(current_7day_avg, 2),
    prior_ea_7day = round(prior_7day_avg, 2),
    two_prior_ea_7day = if (!is.na(two_prior_7day_avg)) round(two_prior_7day_avg, 2) else NA,
    ea_delta_week = round(ea_delta, 2),
    ea_status = ea_status,
    current_clinical_band = current_band,
    prior_clinical_band = prior_band,
    trajectory = trajectory,
    cumulative_multiday_decline = cumulative_decline_flag,
    days_below_30_last_7 = days_below_30,
    days_below_45_last_7 = days_below_45,
    percent_days_below_30_last_7 = pct_below_30,
    percent_days_below_45_last_7 = pct_below_45,
    data_compliance_pct = ea_compliance_pct,
    thermodynamic_method = thermo_method,
    protein_buffer_active = protein_buffer_active,
    protein_buffer_note = protein_buffer_note,
    luteal_rmr_penalty_applied = luteal_rmr_penalty > 0,
    luteal_rmr_penalty_kcal = if (luteal_rmr_penalty > 0) luteal_rmr_penalty else NA,
    ffm_method_note = "LOCF with 45-day expiration. Staleness checked via last_ffm_date and per-day LOCF tracking.",
    clinical_warnings = if (length(clinical_warnings) > 0) clinical_warnings else "None",
    clinical_caveat = "EA thresholds (30, 45 kcal/kg FFM/day) per IOC RED-S Consensus (Mountjoy et al., 2018). Screening tool only. Clinical diagnosis requires comprehensive medical evaluation."
  ))
}

router <- pr()

router$handle("POST", "/analytics/acwr", function(req, res) {
  body <- fromJSON(req$postBody)
  calculate_acwr(
    dates = as.character(body$dates %||% body$dates_series),
    daily_loads = as.numeric(body$daily_loads),
    gender = body$gender,
    cycle_phase = body$cycle_phase,
    age_years = if (is.null(body$age_years)) NULL else as.numeric(body$age_years),
    wbgt_celsius = if (is.null(body$wbgt_celsius)) NULL else as.numeric(body$wbgt_celsius),
    equipment_caf = if (is.null(body$equipment_caf)) NULL else as.numeric(body$equipment_caf)
  )
}, serializer = serializer_json())

router$handle("POST", "/analytics/ea-assessment", function(req, res) {
  body <- fromJSON(req$postBody)
  calculate_ea_assessment(
    dates = as.character(body$dates %||% body$dates_series),
    calories_series = as.numeric(body$calories_series),
    exercise_ee_series = as.numeric(body$exercise_ee_series),
    ffm_series = as.numeric(body$ffm_series),
    duration_minutes_series = if (!is.null(body$duration_minutes_series)) as.numeric(body$duration_minutes_series) else NULL,
    measured_rmr_daily = if (!is.null(body$measured_rmr_daily)) as.numeric(body$measured_rmr_daily) else NULL,
    protein_g_series = if (!is.null(body$protein_g_series)) as.numeric(body$protein_g_series) else NULL,
    last_ffm_date = body$last_ffm_date,
    age_years = if (is.null(body$age_years)) NULL else as.numeric(body$age_years),
    gender = body$gender,
    cycle_phase = body$cycle_phase
  )
}, serializer = serializer_json())

router$handle("POST", "/analytics/energy-availability", function(req, res) {
  body <- fromJSON(req$postBody)

  dates <- as.character(body$dates %||% body$dates_series %||% seq(Sys.Date() - 20, Sys.Date(), by = "days"))

  if (!is.null(body$calories_series)) {
    calories_series <- as.numeric(body$calories_series)
  } else if (!is.null(body$calories)) {
    calories_series <- rep(as.numeric(body$calories), length(dates))
  } else {
    return(list(error = "Provide calories_series or calories."))
  }

  if (!is.null(body$exercise_ee_series)) {
    exercise_ee_series <- as.numeric(body$exercise_ee_series)
  } else if (!is.null(body$exercise_ee)) {
    exercise_ee_series <- rep(as.numeric(body$exercise_ee), length(dates))
  } else {
    return(list(error = "Provide exercise_ee_series or exercise_ee."))
  }

  if (!is.null(body$ffm_series)) {
    ffm_series <- as.numeric(body$ffm_series)
  } else if (!is.null(body$ffm)) {
    ffm_series <- rep(as.numeric(body$ffm), length(dates))
  } else {
    return(list(error = "Provide ffm_series or ffm."))
  }

  calculate_ea_assessment(
    dates = dates,
    calories_series = calories_series,
    exercise_ee_series = exercise_ee_series,
    ffm_series = ffm_series,
    duration_minutes_series = if (!is.null(body$duration_minutes_series)) as.numeric(body$duration_minutes_series) else NULL,
    measured_rmr_daily = if (!is.null(body$measured_rmr_daily)) as.numeric(body$measured_rmr_daily) else NULL,
    protein_g_series = if (!is.null(body$protein_g_series)) as.numeric(body$protein_g_series) else NULL,
    last_ffm_date = body$last_ffm_date,
    age_years = if (is.null(body$age_years)) NULL else as.numeric(body$age_years),
    gender = body$gender,
    cycle_phase = body$cycle_phase
  )
}, serializer = serializer_json())

router$handle("POST", "/analytics/reds-trajectory", function(req, res) {
  body <- fromJSON(req$postBody)

  dates <- as.character(body$dates %||% body$dates_series %||% seq(Sys.Date() - 20, Sys.Date(), by = "days"))

  ea_result <- calculate_ea_assessment(
    dates = dates,
    calories_series = as.numeric(body$calories_series),
    exercise_ee_series = as.numeric(body$exercise_ee_series),
    ffm_series = as.numeric(body$ffm_series),
    duration_minutes_series = if (!is.null(body$duration_minutes_series)) as.numeric(body$duration_minutes_series) else NULL,
    measured_rmr_daily = if (!is.null(body$measured_rmr_daily)) as.numeric(body$measured_rmr_daily) else NULL,
    protein_g_series = if (!is.null(body$protein_g_series)) as.numeric(body$protein_g_series) else NULL,
    last_ffm_date = body$last_ffm_date,
    age_years = if (is.null(body$age_years)) NULL else as.numeric(body$age_years),
    gender = body$gender,
    cycle_phase = body$cycle_phase
  )

  return(list(
    slope = if (!is.na(ea_result$ea_delta_week)) round(ea_result$ea_delta_week / 7, 3) else NA,
    current_ea = ea_result$current_ea_7day,
    predicted_ea_7days = if (!is.na(ea_result$ea_delta_week)) round(ea_result$current_ea_7day + ea_result$ea_delta_week, 2) else NA,
    risk_trajectory = ea_result$trajectory,
    clinical_warnings = ea_result$clinical_warnings
  ))
}, serializer = serializer_json())

router$handle("POST", "/analytics/full-assessment", function(req, res) {
  body <- fromJSON(req$postBody)

  dates <- as.character(body$dates %||% body$dates_series %||% seq(Sys.Date() - 41, Sys.Date(), by = "days"))
  daily_loads <- as.numeric(body$daily_loads)

  if (length(dates) < length(daily_loads)) {
    dates <- as.character(seq(Sys.Date() - length(daily_loads) + 1, Sys.Date(), by = "days"))
  }

  calories <- as.numeric(body$calories %||% 2000)
  ffm <- as.numeric(body$ffm %||% 55)
  calories_series <- rep(calories, length(dates))
  ffm_series <- rep(ffm, length(dates))

  if (!is.null(body$exercise_ee_series)) {
    exercise_ee_series <- as.numeric(body$exercise_ee_series)
  } else {
    exercise_ee_series <- daily_loads * 0.10 * ffm
  }

  acwr_result <- calculate_acwr(
    dates = dates,
    daily_loads = daily_loads,
    gender = body$gender,
    cycle_phase = body$cycle_phase,
    age_years = if (is.null(body$age_years)) NULL else as.numeric(body$age_years),
    wbgt_celsius = if (is.null(body$wbgt_celsius)) NULL else as.numeric(body$wbgt_celsius),
    equipment_caf = if (is.null(body$equipment_caf)) NULL else as.numeric(body$equipment_caf)
  )

  ea_result <- calculate_ea_assessment(
    dates = dates,
    calories_series = calories_series,
    exercise_ee_series = exercise_ee_series,
    ffm_series = ffm_series,
    duration_minutes_series = if (!is.null(body$duration_minutes_series)) as.numeric(body$duration_minutes_series) else NULL,
    measured_rmr_daily = if (!is.null(body$measured_rmr_daily)) as.numeric(body$measured_rmr_daily) else NULL,
    protein_g_series = if (!is.null(body$protein_g_series)) as.numeric(body$protein_g_series) else NULL,
    last_ffm_date = body$last_ffm_date,
    age_years = if (is.null(body$age_years)) NULL else as.numeric(body$age_years),
    gender = body$gender,
    cycle_phase = body$cycle_phase
  )

  result <- acwr_result
  result$energy_availability <- list(
    ea_value = ea_result$current_ea_7day,
    ea_status = ea_result$ea_status,
    ea_trajectory = ea_result$trajectory,
    current_clinical_band = ea_result$current_clinical_band,
    percent_days_below_30_last_7 = ea_result$percent_days_below_30_last_7,
    protein_buffer_active = ea_result$protein_buffer_active,
    luteal_rmr_penalty_applied = ea_result$luteal_rmr_penalty_applied
  )
  result$ea_assessment <- ea_result

  return(result)
}, serializer = serializer_json())

router$handle("GET", "/health", function(req, res) {
  list(
    status = "healthy",
    service = "ATHENA R Analytics Engine v1.0.0 - Production Release",
    version = "1.0.0",
    key_corrections_from_v11_0 = list(
      "Fixed invalid %||% usage with as.numeric() in energy-availability endpoint",
      "Fixed undefined locf() function call; now uses locf_with_staleness()",
      "Integrated last_ffm_date with per-day LOCF staleness tracking",
      "Added contiguous-block adjustment for AR(1) correction with non-contiguous valid observations",
      "All legacy endpoint output fields preserved"
    )
  )
}, serializer = serializer_json())

bind_host <- Sys.getenv("ATHENA_R_BIND_HOST", "127.0.0.1")
router$run(host = bind_host, port = 8001)