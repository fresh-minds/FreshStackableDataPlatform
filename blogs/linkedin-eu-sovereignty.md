# LinkedIn — EU digital sovereignty

*Draft post. English, broad audience, non-technical.*

---

I spent the last month building a data platform, and the question I kept coming
back to wasn't technical. It was this: where does our data actually live, and
who can switch it off?

We talk about "digital sovereignty" in Europe as if it's a slogan. Up close,
it's two separate questions — and both matter.

Sovereignty isn't about building walls or rejecting global technology. It's
about choice. Can you move your platform to another provider without rebuilding
it from scratch? Can you run it on a European cloud, on your own hardware, or
on a laptop — the same system, no rewrite? If the answer is "yes," you're free.
If the answer is "only if you stay where you are," you're not really choosing
your vendor. Your vendor is choosing you.

I've been building a reference data platform that takes this seriously. Not as
a marketing claim, but as an engineering constraint: the exact same platform
has to run on a developer's laptop, on a hyperscaler, and on a European
sovereign cloud — without forking the code. That constraint is uncomfortable.
It forces you to confront every quiet assumption you've baked in about who you
depend on. But it's also the whole point. Portability isn't a feature you add
at the end. It's a decision you make at the start, and then defend every day.

There's a second layer that gets less attention than where the servers are:
governance. Sovereignty over infrastructure means little if you've lost control
over how the data inside it is used. So the harder work was making the rules
explicit and enforceable — who may see what, and crucially, *for what purpose*.
European data-protection law has a quiet, powerful idea at its core: data
collected for one reason shouldn't silently be reused for another. Turning that
principle into something a system actually enforces, rather than a paragraph in
a policy document nobody reads, is where sovereignty stops being abstract.

None of this requires turning our backs on the best technology in the world.
Almost everything here is open source, much of it built by global communities.
Sovereignty and openness aren't opposites — open standards are what *give* you
the exit door. The lock-in we should worry about isn't foreign technology. It's
the kind you can't walk away from.

Europe doesn't need to choose between being open and being in control. We need
systems that are both — portable by design, governed on purpose, and honest
about the trade-offs. That's not a slogan. It's a build target.

Curious how others are thinking about this. Is sovereignty a constraint you're
designing for from day one, or something you're hoping to retrofit later?

#DigitalSovereignty #EU #OpenSource #DataGovernance #DataPrivacy
