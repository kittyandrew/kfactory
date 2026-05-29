package main

type runner struct {
	clientContainer   string
	opencodeContainer string
	ntfyPort          string
	ntfyTopic         string
	repo              string
	token             string
	opencodeBase      string
	ntfyInternal      string
	ntfyURL           string
	db                string
	ws1               string
	ws2               string
	ws3               string
	tickWS            string
}

type workspace struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Branch    string `json:"branch"`
	Directory string `json:"directory"`
}

type session struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspaceID"`
	ParentID    string `json:"parentID"`
	Time        struct {
		Updated float64 `json:"updated"`
	} `json:"time"`
}

type message struct {
	Info struct {
		Role string `json:"role"`
	} `json:"info"`
	Parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"parts"`
}

type ntfyMessage struct {
	Time    int64  `json:"time"`
	Title   string `json:"title"`
	Message string `json:"message"`
}
