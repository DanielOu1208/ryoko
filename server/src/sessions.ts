// One Mimo run per session at a time (design §6.4): a second message gets 409 session_busy.
// W7 keeps the session state (transcript, system prompt) next to this lock.

export class SessionLocks {
  private readonly active = new Set<string>();

  /** Returns a release function, or null if the session already has a run. */
  tryAcquire(sessionId: string): (() => void) | null {
    if (this.active.has(sessionId)) return null;
    this.active.add(sessionId);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.active.delete(sessionId);
    };
  }

  isBusy(sessionId: string): boolean {
    return this.active.has(sessionId);
  }
}

/** Session ids come from the app (a UUID); keep them short and URL-safe. */
export const SESSION_ID = /^[A-Za-z0-9_-]{1,64}$/;
