/*
 * Copyright (c) 2026, luogangyi
 */

package main

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	AscendMinDriverVersionEnvVar  = "XPUSHARE_ASCEND_MIN_DRIVER_VERSION"
	AscendMinDriverVersionDefault = "25.5.0"
)

var semverPattern = regexp.MustCompile(`(\d+)\.(\d+)\.(\d+)`)
var numericIDPattern = regexp.MustCompile(`^\d+$`)

func buildAscendLDLibraryPath() string {
	existing := strings.TrimSpace(os.Getenv("LD_LIBRARY_PATH"))
	candidates := []string{
		"/usr/local/Ascend/driver/lib64/common",
		"/usr/local/Ascend/driver/lib64/driver",
		"/usr/local/Ascend/driver/lib64",
	}

	seen := make(map[string]bool)
	var paths []string
	if existing != "" {
		for _, token := range strings.Split(existing, ":") {
			item := strings.TrimSpace(token)
			if item == "" || seen[item] {
				continue
			}
			seen[item] = true
			paths = append(paths, item)
		}
	}
	for _, item := range candidates {
		if item == "" || seen[item] {
			continue
		}
		seen[item] = true
		paths = append(paths, item)
	}
	return strings.Join(paths, ":")
}

func runNpuSmi(stdin string, args ...string) (string, error) {
	cmd := exec.Command("npu-smi", args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}

	env := os.Environ()
	ldPath := buildAscendLDLibraryPath()
	if ldPath != "" {
		env = append(env, "LD_LIBRARY_PATH="+ldPath)
	}
	cmd.Env = env

	output, err := cmd.CombinedOutput()
	return string(output), err
}

type semVersion struct {
	major int
	minor int
	patch int
}

func parseSemVersion(input string) (semVersion, error) {
	matches := semverPattern.FindStringSubmatch(input)
	if len(matches) != 4 {
		return semVersion{}, fmt.Errorf("no semantic version found in %q", input)
	}

	major, err := strconv.Atoi(matches[1])
	if err != nil {
		return semVersion{}, err
	}
	minor, err := strconv.Atoi(matches[2])
	if err != nil {
		return semVersion{}, err
	}
	patch, err := strconv.Atoi(matches[3])
	if err != nil {
		return semVersion{}, err
	}

	return semVersion{major: major, minor: minor, patch: patch}, nil
}

func compareSemVersion(lhs, rhs semVersion) int {
	if lhs.major != rhs.major {
		if lhs.major > rhs.major {
			return 1
		}
		return -1
	}
	if lhs.minor != rhs.minor {
		if lhs.minor > rhs.minor {
			return 1
		}
		return -1
	}
	if lhs.patch != rhs.patch {
		if lhs.patch > rhs.patch {
			return 1
		}
		return -1
	}
	return 0
}

func ascendMinDriverVersion() string {
	value := strings.TrimSpace(os.Getenv(AscendMinDriverVersionEnvVar))
	if value != "" {
		return value
	}
	return AscendMinDriverVersionDefault
}

func detectAscendDriverVersion() (string, error) {
	output, err := runNpuSmi("", "-v")
	raw := strings.TrimSpace(output)
	if err != nil {
		return "", fmt.Errorf("run npu-smi -v failed: %w, output=%q", err, raw)
	}

	match := semverPattern.FindString(raw)
	if match == "" {
		return "", fmt.Errorf("cannot parse driver version from npu-smi -v output: %q", raw)
	}
	return match, nil
}

func ensureAscendDriverVersion(minVersion string) (string, error) {
	detected, err := detectAscendDriverVersion()
	if err != nil {
		return "", err
	}

	currentParsed, err := parseSemVersion(detected)
	if err != nil {
		return "", fmt.Errorf("parse detected driver version failed: %w", err)
	}
	minParsed, err := parseSemVersion(minVersion)
	if err != nil {
		return "", fmt.Errorf("parse min driver version failed: %w", err)
	}

	if compareSemVersion(currentParsed, minParsed) < 0 {
		return detected, fmt.Errorf("ascend driver %s is lower than required %s", detected, minVersion)
	}

	return detected, nil
}

func parseAscendNpuIDs(visibleTokens []string) ([]string, error) {
	seen := make(map[string]bool)
	var ids []string

	for _, rawToken := range visibleTokens {
		token := strings.TrimSpace(ascendDeviceTokenFromUUID(rawToken))
		if token == "" {
			continue
		}
		if !numericIDPattern.MatchString(token) {
			return nil, fmt.Errorf("unsupported ascend visible device token %q (expected numeric NPU ID)", rawToken)
		}
		if seen[token] {
			continue
		}
		seen[token] = true
		ids = append(ids, token)
	}

	sort.Slice(ids, func(i, j int) bool {
		l, _ := strconv.Atoi(ids[i])
		r, _ := strconv.Atoi(ids[j])
		return l < r
	})
	return ids, nil
}

func queryDeviceShareEnabled(npuID string) (bool, error) {
	raw, err := runNpuSmi("", "info", "-t", "device-share", "-i", npuID, "-c", "0")
	if err != nil {
		return false, fmt.Errorf("query device-share for NPU %s failed: %w, output=%q", npuID, err, strings.TrimSpace(raw))
	}

	for _, line := range strings.Split(raw, "\n") {
		normalized := strings.ToLower(strings.TrimSpace(line))
		if !strings.Contains(normalized, "device-share status") {
			continue
		}
		if strings.Contains(normalized, "true") {
			return true, nil
		}
		if strings.Contains(normalized, "false") {
			return false, nil
		}
		return false, fmt.Errorf("unexpected device-share status line for NPU %s: %q", npuID, line)
	}

	return false, fmt.Errorf("device-share status line not found for NPU %s, output=%q", npuID, strings.TrimSpace(raw))
}

func setDeviceShareEnabled(npuID string) error {
	output, err := runNpuSmi("Y\n", "set", "-t", "device-share", "-i", npuID, "-c", "0", "-d", "1")
	if err != nil {
		return fmt.Errorf("enable device-share for NPU %s failed: %w, output=%q", npuID, err, strings.TrimSpace(output))
	}
	return nil
}

func ensureAscendDeviceShareEnabled(npuIDs []string) error {
	for _, npuID := range npuIDs {
		enabled, err := queryDeviceShareEnabled(npuID)
		if err != nil {
			return err
		}
		if enabled {
			log.Printf("Ascend NPU %s device-share already enabled", npuID)
			continue
		}

		log.Printf("Ascend NPU %s device-share is disabled, enabling it now", npuID)
		if err := setDeviceShareEnabled(npuID); err != nil {
			return err
		}
		enabled, err = queryDeviceShareEnabled(npuID)
		if err != nil {
			return err
		}
		if !enabled {
			return fmt.Errorf("device-share still disabled after setting for NPU %s", npuID)
		}
		log.Printf("Ascend NPU %s device-share enabled successfully", npuID)
	}
	return nil
}

func ensureAscendRuntimeReady(visibleTokens []string) error {
	minVersion := ascendMinDriverVersion()
	driverVersion, err := ensureAscendDriverVersion(minVersion)
	if err != nil {
		return err
	}

	npuIDs, err := parseAscendNpuIDs(visibleTokens)
	if err != nil {
		return err
	}
	if len(npuIDs) == 0 {
		return fmt.Errorf("no ascend NPU IDs parsed from visible tokens %v", visibleTokens)
	}

	if err := ensureAscendDeviceShareEnabled(npuIDs); err != nil {
		return err
	}

	log.Printf("Ascend preflight passed: driver=%s (min=%s), device-share enabled on NPUs %v",
		driverVersion, minVersion, npuIDs)
	return nil
}
