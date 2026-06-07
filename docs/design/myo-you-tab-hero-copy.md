# MYO You Tab: Hero Copy Candidates

- **Author:** Declan (Copy Director)
- **Date:** 2026-06-07
- **Status:** Draft for review

Here are candidate lines for the "You" tab header, designed to frame the screen as MYO reflecting the user's profile, not a settings panel. The goal is to imply remembrance and understanding, fitting the MYO voice.

### Hero Line Candidates

1.  **"This is how I see you, today."**
    - Rationale: Direct, personal, temporal. Implies MYO's perspective and acknowledges evolution.
2.  **"Your story, as I know it."**
    - Rationale: Emphasizes an ongoing narrative, positioning MYO as a witness and keeper of memory.
3.  **"A reflection of our work together."**
    - Rationale: Highlights collaboration and the cumulative effect of their interaction.
4.  **"Your progress, in my memory."**
    - Rationale: Connects directly to the core function of a coach (progress) and MYO's unique capability (memory).
5.  **"The details that make you, you."**
    - Rationale: Focuses on individuality and the specific data MYO holds, without being clinical.
6.  **"I remember what matters to you."**
    - Rationale: Affirms MYO's attentiveness and personal connection, subtly hinting at stored preferences or goals.
7.  **"Here's what I've learned about you."**
    - Rationale: Positions MYO as an active learner, reinforcing its intelligent, adaptive nature.
8.  **"Your path, as we've walked it."**
    - Rationale: Evokes a journey and shared experience, suitable for a coaching relationship.

### Top Pick

**"This is how I see you, today."**

- **Defense:** This line is direct, personal, and immediately establishes the intended asymmetry: MYO is presenting its understanding of the user. "Today" adds a crucial temporal element, implying that this view is current but also subject to change, accommodating both new and returning users. It avoids jargon, is calm, and sets an expectation of reflection rather than configuration. It perfectly positions the "You" tab as MYO's memory of the user, aligning with the wedge of "being remembered, not categorized."

### Second Pick (if templated path is chosen)

**"Your story, as I know it."**

- **Defense:** This choice works well in a templated scenario because "story" is broad enough to encompass both an empty profile (the beginning of a story) and a rich one (a story in progress). It maintains the personal, non-transactional tone and emphasizes MYO's role as a chronicler. It's less dynamic than the top pick but holds its integrity without real-time LLM input.

### Product Questions

1.  **Should the line be LLM-generated per user or templated?**

    **My Read:** The line *should* be LLM-generated per user. The core wedge for MYO is "being remembered, not categorized." A templated line, no matter how well-crafted, can never fully achieve the feeling of genuine, evolving remembrance that a dynamic, context-aware LLM-generated line can. The cost of a Gemini call on tab open is a small price to pay for reinforcing the foundational brand promise. This is a critical touchpoint for user retention, especially for the target demographic who feel unseen by typical gym apps. The feeling of "MYO reading you back to yourself" is best delivered by actual reading, not a pre-written script.

2.  **If templated, should it change based on `pendingProposalCount`?**

    **My Read:** Yes, if forced into a templated approach, the line *must* adapt to `pendingProposalCount`. This is a low-cost way to inject utility and a sense of dynamic interaction into a templated system. Gently nudging users to review pending memory facts ("I've learned new things; let's confirm them.") reinforces MYO's intelligence and the user's agency in shaping their "memory." It turns a static screen into an interactive touchpoint.

### Lines That Would Be WRONG for This Moment

1.  **"Manage your profile."**
    - *Why wrong:* Too transactional, implies configuration, not reflection. Sounds like a generic settings menu.
2.  **"Your journey starts here!"**
    - *Why wrong:* Hype-driven, generic fitness motto. Violates "no hype" and "calm" constraints.
3.  **"Let's optimize your settings."**
    - *Why wrong:* Jargon-laden, impersonal, and again, focuses on tweaking rather than understanding.
4.  **"Welcome back, [User Name]!"**
    - *Why wrong:* While personal, it's too generic as a header for *this* specific tab. It's a greeting, not a framing for the content.
5.  **"See how you're performing."**
    - *Why wrong:* Overly focused on output/metrics, rather than the holistic "you" MYO is trying to remember.
