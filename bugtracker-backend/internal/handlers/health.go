package handlers

import (
	"bugtracker-backend/internal/config"
	"encoding/json"
	"log"
	"net/http"
)

type HealthResponse struct {
	Status  string `json:"status"`
	Version string `json:"version"`
}

func HealthCheck(w http.ResponseWriter, r *http.Request) {
	log.Printf("Health check request received from %s", r.RemoteAddr)
	w.Header().Set("Content-Type", "application/json")
	log.Printf("Sending health check response")
	response := HealthResponse{
		Status:  "ok",
		Version: config.Backend_Version,
	}
	w.WriteHeader(200)
	json.NewEncoder(w).Encode(response)
} 