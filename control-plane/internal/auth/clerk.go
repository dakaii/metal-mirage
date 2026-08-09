package auth

import (
	"net/http"
	"strings"

	"github.com/clerk/clerk-sdk-go/v2"
	clerkhttp "github.com/clerk/clerk-sdk-go/v2/http"
)

type Clerk struct{}

func NewClerk(secretKey string) (*Clerk, error) {
	clerk.SetKey(secretKey)
	return &Clerk{}, nil
}

func (c *Clerk) Middleware(next http.Handler) http.Handler {
	return clerkhttp.WithHeaderAuthorization()(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess, ok := clerk.SessionClaimsFromContext(r.Context())
		if !ok || sess == nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	}))
}

func UserID(r *http.Request) string {
	sess, ok := clerk.SessionClaimsFromContext(r.Context())
	if !ok || sess == nil {
		return ""
	}
	return sess.Subject
}

func HasBearer(r *http.Request) bool {
	return strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ")
}
