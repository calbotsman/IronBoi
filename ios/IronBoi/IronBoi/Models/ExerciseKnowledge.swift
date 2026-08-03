import Foundation

struct ExerciseKnowledge: Equatable {
    let primary: [String]
    let secondary: [String]
    let cues: [String]
    let youtubeVideoId: String?

    static func lookup(_ exerciseName: String) -> ExerciseKnowledge {
        database[exerciseName] ?? ExerciseKnowledge(
            primary: [],
            secondary: [],
            cues: [
                "Use a full, controlled range of motion.",
                "Control the eccentric instead of rushing reps.",
                "Stop if pain changes your mechanics."
            ],
            youtubeVideoId: nil
        )
    }

    private static let database: [String: ExerciseKnowledge] = [
        "Barbell Bench Press": .init(primary: ["Chest"], secondary: ["Triceps", "Front delts"], cues: ["Arch your back, feet flat", "Bar to lower chest, elbows 45-60 degrees", "Drive through your heels", "Squeeze pecs at the top"], youtubeVideoId: "rT7DgCr-3pg"),
        "Incline Dumbbell Press": .init(primary: ["Upper chest"], secondary: ["Front delts", "Triceps"], cues: ["Use a 30-45 degree bench angle", "Find a full stretch at the bottom", "Keep elbows slightly in", "Squeeze at lockout"], youtubeVideoId: "8iPEnn-ltC8"),
        "Diamond Push-ups": .init(primary: ["Triceps"], secondary: ["Chest", "Front delts"], cues: ["Hands form a diamond", "Elbows travel back, not out", "Use full range of motion", "Keep core tight"], youtubeVideoId: "J0DnG1_S92I"),
        "Weighted Dips": .init(primary: ["Chest", "Triceps"], secondary: ["Front delts"], cues: ["Lean forward for chest focus", "Use shoulder-safe depth", "Control the descent", "Lock out at the top"], youtubeVideoId: "2z8JmcrW-As"),
        "Push-ups": .init(primary: ["Chest"], secondary: ["Triceps", "Front delts"], cues: ["Hands just outside shoulders", "Keep core rigid", "Use full range of motion", "Control both directions"], youtubeVideoId: "IODxDxX7oi4"),
        "Overhead Press": .init(primary: ["Front delts", "Side delts"], secondary: ["Triceps", "Upper chest"], cues: ["Start at the clavicle", "Press vertically, not forward", "Lock out fully", "Brace abs hard"], youtubeVideoId: "2yjwXTZQDDI"),
        "Dumbbell Shoulder Press": .init(primary: ["Front delts", "Side delts"], secondary: ["Triceps"], cues: ["Use neutral or pronated grip", "Do not arc behind the head", "Control the descent", "Keep both sides even"], youtubeVideoId: "qEwKCR5JCog"),
        "Arnold Press": .init(primary: ["Front delts", "Side delts"], secondary: ["Rear delts", "Triceps"], cues: ["Rotate from palms-in to out", "Move smoothly through the arc", "Slow down on the way down", "Do not rush the rotation"], youtubeVideoId: "6Z15_WdXmVw"),
        "Lateral Raises": .init(primary: ["Side delts"], secondary: ["Rear delts"], cues: ["Slight forward lean", "Lead with elbows, not hands", "Stop near shoulder height", "Do not shrug"], youtubeVideoId: "3VcKaXpzqRo"),
        "KB Clean & Press": .init(primary: ["Front delts", "Side delts"], secondary: ["Traps", "Triceps", "Glutes"], cues: ["Hike the kettlebell back", "Keep rack tight to body", "Press straight overhead", "Hinge instead of squatting the clean"], youtubeVideoId: "0Y6-JI2o7uQ"),
        "Heavy Club Mill": .init(primary: ["Side delts", "Rear delts"], secondary: ["Lats", "Core"], cues: ["Keep the arm extended", "Rotate from the shoulder", "Control arc speed", "Keep wrist neutral"], youtubeVideoId: nil),
        "Heavy Club Shield Cast": .init(primary: ["Front delts", "Chest"], secondary: ["Core", "Triceps"], cues: ["Start from order position", "Swing across the body smoothly", "Control the return", "Brace core throughout"], youtubeVideoId: nil),
        "Skull Crushers": .init(primary: ["Triceps"], secondary: [], cues: ["Lower bar toward forehead or behind", "Keep upper arms vertical", "Do not flare elbows", "Reach full extension"], youtubeVideoId: "d_KZxkY_0cM"),
        "Overhead Tricep Extension": .init(primary: ["Triceps"], secondary: [], cues: ["Keep elbows narrow", "Find the stretch at bottom", "Brace core while standing", "Use a slow eccentric"], youtubeVideoId: "YbX7Wd8jQ-Q"),
        "Deadlift": .init(primary: ["Hamstrings", "Glutes"], secondary: ["Lats", "Erectors", "Traps"], cues: ["Hinge instead of squatting", "Keep bar over mid-foot", "Chest up and lats tight", "Drive the floor away"], youtubeVideoId: "op9kVnSso6Q"),
        "Romanian Deadlift": .init(primary: ["Hamstrings", "Glutes"], secondary: ["Erectors"], cues: ["Keep a soft knee", "Push hips back", "Feel hamstrings stretch", "Do not round lower back"], youtubeVideoId: "JCXUYuzwNrM"),
        "Bent-over Barbell Row": .init(primary: ["Lats", "Mid back"], secondary: ["Biceps", "Rear delts"], cues: ["Set torso around 45 degrees", "Pull to lower chest or navel", "Squeeze shoulder blades", "Control the descent"], youtubeVideoId: "FWJR5Ve8bnQ"),
        "Inverted Row": .init(primary: ["Lats", "Mid back"], secondary: ["Biceps", "Rear delts"], cues: ["Keep body straight", "Pull chest to bar", "Squeeze at top", "More horizontal is harder"], youtubeVideoId: "KOaCM1HMwU0"),
        "Single-arm DB Row": .init(primary: ["Lats"], secondary: ["Biceps", "Mid back"], cues: ["Support yourself on bench", "Pull elbow back and up", "Find full stretch at bottom", "Avoid rotating torso"], youtubeVideoId: "pYcpY20QaE8"),
        "KB Single-arm Row": .init(primary: ["Lats"], secondary: ["Biceps", "Rear delts"], cues: ["Use a staggered stance", "Pull kettlebell to hip", "Squeeze at top", "Control the drop"], youtubeVideoId: "roCP6wCXPqo"),
        "KB Halo": .init(primary: ["Side delts", "Rear delts"], secondary: ["Core", "Traps"], cues: ["Keep kettlebell close to head", "Make a tight controlled circle", "Alternate directions", "Do not tilt your head"], youtubeVideoId: "E2A_AKIxazg"),
        "Sandbag Carry": .init(primary: ["Traps", "Core"], secondary: ["Biceps", "Lats"], cues: ["Hug bag to chest or shoulder", "Stay tall", "Use short powerful steps", "Brace the whole way"], youtubeVideoId: "LWzHa7XDGAk"),
        "Hammer Curls": .init(primary: ["Biceps"], secondary: ["Brachialis", "Forearms"], cues: ["Keep neutral grip", "Do not swing", "Reach full extension", "Control the squeeze"], youtubeVideoId: "TwD-YGVP4Bk"),
        "EZ Bar Curl": .init(primary: ["Biceps"], secondary: ["Brachialis"], cues: ["Pin elbows to ribs", "Do not let elbows drift forward", "Squeeze at top", "Use a slow eccentric"], youtubeVideoId: "zG2i9RGNL4A"),
        "Incline Dumbbell Curl": .init(primary: ["Biceps"], secondary: ["Brachialis"], cues: ["Use incline to stretch long head", "Use full range", "Do not swing back", "Lower slowly"], youtubeVideoId: "soxrZlIl35U"),
        "KB Curl": .init(primary: ["Biceps"], secondary: ["Forearms"], cues: ["Keep horns facing up at top", "Control every rep", "Pin elbows to ribs", "Squeeze at peak"], youtubeVideoId: "iszz-BGIY7s"),
        "Barbell Back Squat": .init(primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Erectors"], cues: ["Bar on upper traps, not neck", "Knees track over toes", "Break parallel if comfortable", "Keep chest up"], youtubeVideoId: "bEv6CCg2BC8"),
        "Walking Lunges": .init(primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"], cues: ["Take a big step forward", "Back knee grazes floor", "Keep torso upright", "Drive through front heel"], youtubeVideoId: "L8fvypPrzzs"),
        "Bulgarian Split Squat": .init(primary: ["Quads", "Glutes"], secondary: ["Hamstrings"], cues: ["Place front foot far enough forward", "Use a slight torso lean", "Control the descent", "Do not let front knee cave"], youtubeVideoId: "2C-uNgKwPLE"),
        "KB Goblet Squat": .init(primary: ["Quads", "Glutes"], secondary: ["Core", "Adductors"], cues: ["Hold kettlebell at chest", "Track elbows inside knees", "Sit deep with chest tall", "Drive heels into floor"], youtubeVideoId: "MeIiIdhvXT4"),
        "Hip Thrust": .init(primary: ["Glutes"], secondary: ["Hamstrings", "Core"], cues: ["Upper back on bench", "Bar over hip crease", "Drive hips to ceiling", "Squeeze hard at top"], youtubeVideoId: "xDmFkJxPzeM"),
        "KB Swing": .init(primary: ["Hamstrings", "Glutes"], secondary: ["Core", "Lats"], cues: ["It is a hinge, not a squat", "Hike kettlebell back", "Explode hips forward", "Arms guide the bell"], youtubeVideoId: "sSESeQAir2M"),
        "Standing Calf Raises": .init(primary: ["Calves"], secondary: [], cues: ["Use full stretch at bottom", "Pause at top", "Slow eccentric", "Keep both legs even"], youtubeVideoId: "gwLzBJYoWlA"),
        "Plank": .init(primary: ["Core"], secondary: ["Chest", "Front delts"], cues: ["Keep body arrow-straight", "Do not let hips sag", "Breathe steadily", "Push floor away"], youtubeVideoId: "ASdvN_XEl_c"),
        "Hanging Leg Raises": .init(primary: ["Core"], secondary: ["Hip flexors", "Lats"], cues: ["Posterior tilt before raising", "Control the lowering", "Do not swing", "Squeeze abs"], youtubeVideoId: "hdng3uzCKX8"),
        "Med Ball Slam": .init(primary: ["Core", "Lats"], secondary: ["Front delts", "Glutes"], cues: ["Reach fully overhead", "Slam through floor", "Catch on bounce", "Brace every rep"], youtubeVideoId: "4YRB9M6OiDE"),
        "Sandbag Clean & Squat": .init(primary: ["Quads", "Glutes"], secondary: ["Lats", "Core", "Traps"], cues: ["Clean from floor to rack", "Receive in partial squat", "Stand to full extension", "Control the drop"], youtubeVideoId: nil),
        "HIIT Sprints (20s on/10s off)": .init(primary: ["Quads", "Hamstrings"], secondary: ["Glutes", "Calves"], cues: ["Drive arms and legs", "Stay on balls of feet", "Use full effort each interval", "Walk recovery if needed"], youtubeVideoId: nil),
        "Zone 2 Walk/Jog": .init(primary: ["Quads", "Hamstrings"], secondary: ["Glutes", "Calves"], cues: ["Use conversational pace", "Try nasal breathing if possible", "Aim for 30-45 minutes", "Build aerobic base"], youtubeVideoId: nil),
        "Foam Rolling": .init(primary: ["Core"], secondary: [], cues: ["Spend 30 seconds per muscle group", "Roll slowly and pause on tender spots", "Breathe into pressure", "Do not roll joints"], youtubeVideoId: nil),
        "Stretching Circuit": .init(primary: ["Core"], secondary: [], cues: ["Hold stretches 30-60 seconds", "Breathe out into stretch", "Never bounce", "Use after training or separately"], youtubeVideoId: nil),

        // MARK: Swap-catalog alternates
        // Every entry below exists because the server's swap catalog
        // (functions/src/workouts/exerciseCatalog.ts) can put it into a plan.
        // A swappable exercise with no entry here renders a hollow detail
        // sheet — "None listed" muscles and three generic cues — so the two
        // lists must stay in lockstep: add there, add here. Muscles mirror
        // the catalog exactly. videoId is nil rather than guessed; the sheet
        // falls back to a YouTube search, which is honest where a fabricated
        // video id is not.
        "Incline Push-ups": .init(primary: ["Chest"], secondary: ["Triceps", "Front delts"], cues: ["Hands on a bench or box", "Body straight from head to heels", "Lower chest to the edge", "The higher the hands, the easier"], youtubeVideoId: nil),
        "Decline Push-ups": .init(primary: ["Upper chest"], secondary: ["Triceps", "Front delts"], cues: ["Feet elevated on a bench", "Keep hips in line, don't sag", "Lower until forehead nears floor", "Harder than flat — expect fewer reps"], youtubeVideoId: nil),
        "Dumbbell Bench Press": .init(primary: ["Chest"], secondary: ["Triceps", "Front delts"], cues: ["Feet planted, slight arch", "Lower to the outside of the chest", "Press up and slightly in", "Control the dumbbells at lockout"], youtubeVideoId: nil),
        "Dumbbell Floor Press": .init(primary: ["Chest"], secondary: ["Triceps"], cues: ["Lie on the floor, knees bent", "Upper arms touch down softly each rep", "Pause briefly at the floor", "Press without bouncing the elbows"], youtubeVideoId: nil),
        "Pike Push-ups": .init(primary: ["Front delts", "Side delts"], secondary: ["Triceps"], cues: ["Hips high in an inverted V", "Lower the crown of your head to the floor", "Elbows track back, not flared", "Walk feet closer to make it harder"], youtubeVideoId: nil),
        "Band Lateral Raise": .init(primary: ["Side delts"], secondary: ["Rear delts"], cues: ["Stand on the band, handles at sides", "Lead with the elbows", "Stop at shoulder height", "Resist the band on the way down"], youtubeVideoId: nil),
        "Bench Dips": .init(primary: ["Triceps"], secondary: ["Chest", "Front delts"], cues: ["Hands on the bench edge behind you", "Keep hips close to the bench", "Elbows point straight back", "Stop if the front of the shoulder complains"], youtubeVideoId: nil),
        "Pull-ups": .init(primary: ["Lats"], secondary: ["Biceps", "Mid back"], cues: ["Overhand grip, just outside shoulders", "Pull the chest to the bar", "Full hang at the bottom", "No kipping — control both directions"], youtubeVideoId: nil),
        "Chin-ups": .init(primary: ["Lats", "Biceps"], secondary: ["Mid back"], cues: ["Underhand grip, shoulder width", "Drive elbows down and back", "Chin over the bar, chest tall", "Lower slowly to a dead hang"], youtubeVideoId: nil),
        "Band Row": .init(primary: ["Lats", "Mid back"], secondary: ["Biceps", "Rear delts"], cues: ["Anchor the band at chest height", "Pull to the lower ribs", "Squeeze the shoulder blades together", "Don't let the band yank you forward"], youtubeVideoId: nil),
        "Superman Hold": .init(primary: ["Erectors"], secondary: ["Glutes", "Rear delts"], cues: ["Lie face down, arms extended", "Lift chest and thighs together", "Squeeze glutes, look at the floor", "Hold and breathe — don't crank the neck"], youtubeVideoId: nil),
        "Back Extension": .init(primary: ["Erectors"], secondary: ["Glutes", "Hamstrings"], cues: ["Hinge over the pad, not the ribs", "Rise to a straight line, no higher", "Squeeze glutes at the top", "Slow on the way down"], youtubeVideoId: nil),
        "Good Morning": .init(primary: ["Erectors", "Hamstrings"], secondary: ["Glutes"], cues: ["Bar on upper traps, soft knees", "Push hips back until hamstrings load", "Keep the back flat throughout", "Start light — this bites the next day"], youtubeVideoId: nil),
        "Dumbbell Romanian Deadlift": .init(primary: ["Hamstrings", "Glutes"], secondary: ["Erectors"], cues: ["Dumbbells slide down the thighs", "Push hips straight back", "Stop at the hamstring stretch", "Stand up by driving hips forward"], youtubeVideoId: nil),
        "Single-leg Romanian Deadlift": .init(primary: ["Hamstrings", "Glutes"], secondary: ["Core", "Erectors"], cues: ["Hinge on one leg, back leg reaches behind", "Square hips to the floor", "Light touch on a wall is fine for balance", "Feel the standing hamstring, not the back"], youtubeVideoId: nil),
        "Glute Bridge": .init(primary: ["Glutes"], secondary: ["Hamstrings", "Core"], cues: ["Heels close to the hips", "Drive through the heels", "Squeeze hard at the top, ribs down", "Don't arch the lower back to go higher"], youtubeVideoId: nil),
        "Nordic Hamstring Curl": .init(primary: ["Hamstrings"], secondary: ["Glutes", "Core"], cues: ["Anchor the ankles firmly", "Lower as slowly as you can", "Keep hips extended — no folding", "Push back up with hands as needed"], youtubeVideoId: nil),
        "Bodyweight Squat": .init(primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"], cues: ["Feet shoulder width, toes slightly out", "Sit down between the knees", "Chest tall, heels planted", "Full depth if the knees are happy"], youtubeVideoId: nil),
        "Dumbbell Goblet Squat": .init(primary: ["Quads", "Glutes"], secondary: ["Core", "Adductors"], cues: ["Hold one dumbbell at the chest", "Elbows track inside the knees", "Sit deep with the chest tall", "Drive the floor away to stand"], youtubeVideoId: nil),
        "Reverse Lunge": .init(primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"], cues: ["Step back, not forward", "Back knee grazes the floor", "Front shin stays vertical", "Push through the front heel to return"], youtubeVideoId: nil),
        "Step-ups": .init(primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Calves"], cues: ["Whole foot on the box or bench", "Drive through the top leg — don't jump off the bottom one", "Stand fully tall at the top", "Control the step down"], youtubeVideoId: nil),
        "Wall Sit": .init(primary: ["Quads"], secondary: ["Glutes", "Core"], cues: ["Back flat on the wall", "Thighs parallel to the floor", "Weight through the heels", "Breathe — don't hold your breath"], youtubeVideoId: nil),
        "Single-leg Calf Raise": .init(primary: ["Calves"], secondary: [], cues: ["Ball of the foot on an edge", "Full stretch at the bottom", "Pause at the top", "Fingertips on a wall for balance only"], youtubeVideoId: nil),
        "Dead Bug": .init(primary: ["Core"], secondary: ["Hip flexors"], cues: ["Lower back pressed into the floor", "Opposite arm and leg extend together", "Move slowly, exhale as you reach", "Stop the rep if the back arches"], youtubeVideoId: nil),
        "Hollow Body Hold": .init(primary: ["Core"], secondary: ["Hip flexors"], cues: ["Lower back glued to the floor", "Arms and legs long and low", "Shorten the lever if it breaks form", "Breathe shallow and steady"], youtubeVideoId: nil),
        "Side Plank": .init(primary: ["Core"], secondary: ["Side delts", "Glutes"], cues: ["Elbow under the shoulder", "Body in one straight line", "Push the floor away, hips high", "Stack or stagger the feet"], youtubeVideoId: nil),
        "Bird Dog": .init(primary: ["Core"], secondary: ["Erectors", "Glutes"], cues: ["Hands under shoulders, knees under hips", "Reach opposite arm and leg", "Keep the hips level — no tilting", "Pause, then switch slowly"], youtubeVideoId: nil),
        "Mountain Climbers": .init(primary: ["Core"], secondary: ["Quads", "Front delts"], cues: ["Strong plank, hands under shoulders", "Drive knees toward the chest", "Keep hips low and level", "Pick a pace you can hold"], youtubeVideoId: nil),
        "Burpees": .init(primary: ["Quads", "Chest"], secondary: ["Core", "Front delts"], cues: ["Chest to the floor each rep", "Snap the hips to stand", "Jump and reach at the top", "Pace steady — quality over speed"], youtubeVideoId: nil),
        "Jump Rope": .init(primary: ["Calves", "Quads"], secondary: ["Core"], cues: ["Jump from the ankles, not the knees", "Stay tall, elbows close", "Small hops — an inch of air is enough", "Land softly on the balls of the feet"], youtubeVideoId: nil),
        "Incline Walk": .init(primary: ["Quads", "Glutes"], secondary: ["Calves"], cues: ["Set a grade you can hold for 20+ minutes", "Don't hang on the rails", "Lean slightly into the hill", "Conversational pace builds the base"], youtubeVideoId: nil),
        "Farmer Carry": .init(primary: ["Traps", "Core"], secondary: ["Forearms"], cues: ["Heavy dumbbell in each hand", "Walk tall — shoulders back and down", "Short, quick steps", "Brace like someone might poke you"], youtubeVideoId: nil),
        "Suitcase Carry": .init(primary: ["Core", "Traps"], secondary: ["Forearms"], cues: ["One heavy weight, one side", "Do not lean away from the load", "Walk a straight line, eyes ahead", "Switch sides evenly"], youtubeVideoId: nil)
    ]
}
