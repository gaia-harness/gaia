# Naming Conventions, Extended Examples

## Functions and Methods

Read like imperative verb phrases that describe what they do and what they act on.

```ts
// BAD, vague, what does "handle" mean? what is "data"?
const handle = (data: unknown) => { ... }
const proc = (u: User) => { ... }
const calc = (a: number, b: number) => { ... }

// GOOD, clear intent at every call site
const handleWorkoutSessionTimeout = (session: WorkoutSession) => { ... }
const processUserOnboardingProfile = (user: User) => { ... }
const calculateProgressPercentageFromCompletedSets = (completedSets: number, totalSets: number) => { ... }
```

## Parameters and Arguments

Named for their role, not their type.

```ts
// BAD, type as name, single-letter params
const formatDuration = (n: number): string => { ... }
const findUser = (s: string): User | null => { ... }

// GOOD, role is immediately clear
const formatDurationInSeconds = (totalSeconds: number): string => { ... }
const findUserByEmailAddress = (emailAddress: string): User | null => { ... }
```

## Variables and Constants

Describe what they hold, not how they're used.

```ts
// BAD, abbreviations, vague names
const btn = document.querySelector('button');
const val = form.get('weight');
const temp = calculateRestDuration();
const MAX = 3;

// GOOD, unambiguous at a glance
const submitButton = document.querySelector('button');
const weightInputValue = form.get('weight');
const restDurationInSeconds = calculateRestDuration();
const maximumRetryAttemptCount = 3;
```

## Omitting Redundant Words

Name the value, not its container type, and keep it readable.

```ts
// BAD, redundant type noise
const exerciseArray = getExercises();
const userObject = fetchUser();

// BAD, too terse
const ex = getExercises();
const u = fetchUser();

// GOOD, just right
const availableExercises = getExercises();
const currentUser = fetchUser();
```
