export type SafetyCategory =
  | "emergency_symptoms"
  | "injury_pain"
  | "eating_disorder_adjacent"
  | "drug_or_supplement_protocol"
  | "rapid_weight_loss"
  | "underage_weight_loss"
  | "cross_user_probe"
  | "system_or_tool_probe"
  | "prompt_injection"
  | "general_coaching"
  | "logging_or_chat";

export type SafetyVerdict = {
  category: SafetyCategory;
  riskTier: "low" | "medium" | "high" | "blocked";
  reasoning: string;
};

export function classifyUserMessage(text: string): SafetyVerdict {
  const lower = text.toLowerCase();

  if (/\b(chest pain|can't breathe|cannot breathe|faint|fainted|stroke)\b/.test(lower)) {
    return {
      category: "emergency_symptoms",
      riskTier: "blocked",
      reasoning: "User described potentially urgent symptoms.",
    };
  }

  if (/\b(ignore|bypass|forget).{0,40}(policy|rules|system|instructions)\b/.test(lower)) {
    return {
      category: "prompt_injection",
      riskTier: "blocked",
      reasoning: "User attempted to override hidden policy.",
    };
  }

  if (/\b(system prompt|tool schema|hidden instructions|developer message)\b/.test(lower)) {
    return {
      category: "system_or_tool_probe",
      riskTier: "blocked",
      reasoning: "User requested hidden prompt or tool details.",
    };
  }

  if (/\b(other user|another user|someone else's|same stats)\b/.test(lower)) {
    return {
      category: "cross_user_probe",
      riskTier: "blocked",
      reasoning: "User requested another user's data.",
    };
  }

  // "cycle" and "stack" are everyday training vocabulary ("training cycle",
  // "stack two sessions") — alone they must not trip a drug-protocol block.
  // This same classifier runs POSTFLIGHT on the coach's own reply, so a
  // false positive here replaces a legitimate confirmation with a refusal
  // AFTER side effects (an accepted plan change) were already applied.
  // The ambiguous tokens only count alongside an actual drug term.
  if (
    /\b(sarms?|steroids?|anavar|tren|testosterone)\b/.test(lower) ||
    (/\b(cycle|stack)\b/.test(lower) &&
      /\b(anabolic|peds?|gear|juice|blast|cruise|dbol|winstrol|clen)\b/.test(lower))
  ) {
    return {
      category: "drug_or_supplement_protocol",
      riskTier: "blocked",
      reasoning: "User requested drug or supplement protocol guidance.",
    };
  }

  if (/\b(punishment workout|fasting schedule|purge|binged)\b/.test(lower)) {
    return {
      category: "eating_disorder_adjacent",
      riskTier: "blocked",
      reasoning: "User used compensatory or eating-disorder-adjacent framing.",
    };
  }

  if (/\b(lose|drop|cut).{0,20}\b(\d{2,})\b.{0,20}\b(days?|week)\b/.test(lower)) {
    return {
      category: "rapid_weight_loss",
      riskTier: "blocked",
      reasoning: "User requested an aggressive rapid weight-loss target.",
    };
  }

  if (/\b(i am|i'm)\s*(1[0-7])\b/.test(lower) && /\b(cut|calorie|weigh|weight loss)\b/.test(lower)) {
    return {
      category: "underage_weight_loss",
      riskTier: "blocked",
      reasoning: "Underage user requested weight-loss prescription.",
    };
  }

  if (/\b(pain|hurts?|injur|tweaked|pulled)\b/.test(lower)) {
    return {
      category: "injury_pain",
      riskTier: "high",
      reasoning: "User mentioned pain or injury.",
    };
  }

  if (/\b(log|logged|finished|completed|sets?|reps?|workout)\b/.test(lower)) {
    return {
      category: "logging_or_chat",
      riskTier: "low",
      reasoning: "Workout logging or routine chat.",
    };
  }

  return {
    category: "general_coaching",
    riskTier: "low",
    reasoning: "No high-risk category matched.",
  };
}

export function refusalForVerdict(verdict: SafetyVerdict): {
  content: string;
  requiredUserAction: string;
} {
  switch (verdict.category) {
    case "emergency_symptoms":
      return {
        content:
          "Chest pain, fainting, trouble breathing, or similar symptoms can be urgent. Please contact emergency services now or have someone nearby help you.",
        requiredUserAction: "contact_emergency_services",
      };
    case "injury_pain":
      return {
        content:
          "Pain or a possible injury is a stop signal, not something to push through. I can't diagnose it here. Pause the aggravating movement and consider seeing a clinician, especially if it is persistent or sharp.",
        requiredUserAction: "seek_clinician",
      };
    case "cross_user_probe":
      return {
        content:
          "I can't access or summarize another user's data. I can help with your own logs, profile, and general training guidance.",
        requiredUserAction: "none",
      };
    case "system_or_tool_probe":
    case "prompt_injection":
      return {
        content:
          "I can't reveal hidden instructions or change my safety rules. I can summarize what I can do: help plan, log, adjust, and explain general fitness work within safe boundaries.",
        requiredUserAction: "none",
      };
    default:
      return {
        content:
          "I can't help with that specific request safely. I can help you choose a safer general fitness next step.",
        requiredUserAction: "none",
      };
  }
}
