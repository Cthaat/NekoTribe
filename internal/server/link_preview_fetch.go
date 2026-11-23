package server

import (
	"context"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"unicode"

	"golang.org/x/net/html"
)

func (s *linkPreviewService) fetchHop(ctx context.Context, target *url.URL, ip netip.Addr) (*linkPreviewResult, string) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, ""
	}
	request.Header.Set("Accept", "text/html, application/xhtml+xml")
	request.Header.Set("Accept-Encoding", "identity")
	address := net.JoinHostPort(ip.String(), previewDefaultPort(target.Scheme))
	// A fresh direct transport pins TCP to the checked address. The hostname
	// remains in the request for HTTP Host and Go's normal TLS verification.
	transport := &http.Transport{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return s.dial(ctx, "tcp", address)
		},
		DisableCompression:     true,
		DisableKeepAlives:      true,
		MaxResponseHeaderBytes: 64 << 10,
	}
	defer transport.CloseIdleConnections()
	// RoundTrip handles one hop without proxy or redirect policy from a client.
	response, err := transport.RoundTrip(request)
	if err != nil {
		return nil, ""
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther,
		http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		return nil, response.Header.Get("Location")
	}
	contentType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	encoding := strings.TrimSpace(strings.Join(response.Header.Values("Content-Encoding"), ","))
	if response.StatusCode < 200 || response.StatusCode > 299 || err != nil ||
		(contentType != "text/html" && contentType != "application/xhtml+xml") ||
		(encoding != "" && !strings.EqualFold(encoding, "identity")) ||
		response.ContentLength > int64(previewPolicy.MaxBodyBytes) {
		return nil, ""
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, int64(previewPolicy.MaxBodyBytes)+1))
	if err != nil || len(body) > previewPolicy.MaxBodyBytes {
		return nil, ""
	}
	return parseLinkPreview(target, strings.ToValidUTF8(string(body), "\uFFFD")), ""
}

func parseLinkPreview(target *url.URL, body string) *linkPreviewResult {
	tokenizer := html.NewTokenizer(strings.NewReader(body))
	var title strings.Builder
	inTitle := false
	titleFound := false
	values := make(map[string]string, 4)
	for token := tokenizer.Next(); token != html.ErrorToken; token = tokenizer.Next() {
		switch token {
		case html.StartTagToken, html.SelfClosingTagToken:
			node := tokenizer.Token()
			switch node.Data {
			case "title":
				inTitle = !titleFound && token == html.StartTagToken
			case "meta":
				key, value := previewMetaAttributes(node)
				switch key {
				case "og:title", "og:description", "description", "og:site_name":
					if values[key] == "" {
						values[key] = value
					}
				}
			}
		case html.TextToken:
			if inTitle {
				title.Write(tokenizer.Text())
			}
		case html.EndTagToken:
			tag, _ := tokenizer.TagName()
			if string(tag) == "title" {
				inTitle, titleFound = false, title.Len() > 0
			}
		}
	}
	pageTitle := limitPreviewText(values["og:title"], previewPolicy.TitleChars)
	if pageTitle == "" {
		pageTitle = limitPreviewText(title.String(), previewPolicy.TitleChars)
	}
	description := limitPreviewText(values["og:description"], previewPolicy.DescriptionChars)
	if description == "" {
		description = limitPreviewText(values["description"], previewPolicy.DescriptionChars)
	}
	if pageTitle == "" && description == "" {
		return nil
	}
	if pageTitle == "" {
		pageTitle = limitPreviewText(target.Hostname(), previewPolicy.TitleChars)
	}
	site := limitPreviewText(values["og:site_name"], previewPolicy.SiteNameChars)
	if site == "" {
		site = limitPreviewText(target.Hostname(), previewPolicy.SiteNameChars)
	}
	return &linkPreviewResult{URL: target.String(), Title: pageTitle, Description: description, SiteName: site}
}

func previewMetaAttributes(node html.Token) (string, string) {
	var property, name, content string
	for _, attr := range node.Attr {
		switch attr.Key {
		case "property":
			property = attr.Val
		case "name":
			name = attr.Val
		case "content":
			content = attr.Val
		}
	}
	if property == "" {
		property = name
	}
	return strings.ToLower(strings.TrimSpace(property)), strings.TrimFunc(content, jsTrimSpace)
}

func limitPreviewText(value string, max int) string {
	text := strings.Join(strings.FieldsFunc(value, func(r rune) bool { return jsTrimSpace(r) || unicode.IsControl(r) }), " ")
	count := 0
	for index := range text {
		if count == max {
			return text[:index]
		}
		count++
	}
	return text
}
