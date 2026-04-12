// meee2 Landing Page - JavaScript

// Supabase configuration
const SUPABASE_URL = 'https://mpypmxskhowzumxgaxnr.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1weXBteHNraG93enVteGdheG5yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU4Mjg5MDcsImV4cCI6MjA5MTQwNDkwN30.OYvnj4eSDkDXrSxo7IN3H78JXG3oyOhy3jhdvTw4FSg';

// Initialize Supabase client
let supabaseClient;
try {
    supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    console.log('Supabase client initialized');
} catch (e) {
    console.error('Failed to init Supabase:', e);
}

document.addEventListener('DOMContentLoaded', function() {
    // Initialize scroll animations
    initScrollAnimations();

    // Initialize smooth scroll
    initSmoothScroll();

    // Initialize navigation highlight
    initNavHighlight();

    // Fetch user count from Supabase
    fetchUserCount();
});

// Scroll animations using Intersection Observer
function initScrollAnimations() {
    const observerOptions = {
        root: null,
        rootMargin: '0px',
        threshold: 0.1
    };

    const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry, index) => {
            if (entry.isIntersecting) {
                // Add staggered delay
                setTimeout(() => {
                    entry.target.classList.add('visible');
                }, index * 100);
            }
        });
    }, observerOptions);

    // Observe all animated elements
    const animatedElements = document.querySelectorAll('.feature-card, .integration-card, .install-step');
    animatedElements.forEach(el => observer.observe(el));
}

// Smooth scroll for anchor links
function initSmoothScroll() {
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function(e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute('href'));
            if (target) {
                const navHeight = document.querySelector('.nav').offsetHeight;
                const targetPosition = target.getBoundingClientRect().top + window.pageYOffset - navHeight - 20;

                window.scrollTo({
                    top: targetPosition,
                    behavior: 'smooth'
                });
            }
        });
    });
}

// Navigation highlight on scroll
function initNavHighlight() {
    const sections = document.querySelectorAll('section[id]');
    const navLinks = document.querySelectorAll('.nav-links a');

    window.addEventListener('scroll', () => {
        let current = '';
        const navHeight = document.querySelector('.nav').offsetHeight;

        sections.forEach(section => {
            const sectionTop = section.offsetTop - navHeight - 100;
            const sectionHeight = section.offsetHeight;

            if (window.pageYOffset >= sectionTop && window.pageYOffset < sectionTop + sectionHeight) {
                current = section.getAttribute('id');
            }
        });

        navLinks.forEach(link => {
            link.style.color = '';
            if (link.getAttribute('href') === `#${current}`) {
                link.style.color = '#ffffff';
            }
        });
    });
}

// Copy configuration to clipboard
function copyConfig() {
    const config = `{
  "hooks": {
    "SessionStart": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "PreToolUse": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "PostToolUse": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "PermissionRequest": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "Notification": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "Stop": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }],
    "UserPromptSubmit": [{
      "command": "/Applications/meee2.app/Contents/Resources/Bridge/meee2-bridge --source claude"
    }]
  }
}`;

    navigator.clipboard.writeText(config).then(() => {
        // Show success feedback
        const btn = document.querySelector('.copy-btn');
        const originalText = btn.textContent;
        btn.textContent = 'Copied!';
        btn.style.color = '#22c55e';

        setTimeout(() => {
            btn.textContent = originalText;
            btn.style.color = '';
        }, 2000);
    }).catch(err => {
        console.error('Failed to copy: ', err);
    });
}

// Fetch user count from Supabase RPC function
async function fetchUserCount() {
    const userCountEl = document.getElementById('user-count');

    if (!supabaseClient) {
        console.warn('Supabase client not initialized');
        userCountEl.textContent = '100+';
        return;
    }

    try {
        console.log('Calling get_user_count RPC...');
        const { data, error } = await supabaseClient.rpc('get_user_count');

        if (error) {
            console.error('Supabase RPC error:', error);
            userCountEl.textContent = '100+';
            return;
        }

        console.log('User count:', data);
        const count = data || 0;
        userCountEl.textContent = formatNumber(count);
    } catch (err) {
        console.error('Failed to fetch user count:', err);
        userCountEl.textContent = '100+';
    }
}

// Format number with base count for launch display
function formatNumber(num) {
    return (num + 1000).toString();
}

// Copy plugin creation prompt
function copyPluginPrompt() {
    const prompt = `Create a meee2 plugin for [YOUR_TOOL_NAME]:

Requirements:
- Plugin ID: com.meee2.plugin.[name]
- Display name: [Your Tool Name]
- Icon: [SF Symbol name]
- Theme color: [SwiftUI Color]

The plugin should:
1. Monitor [describe your tool's session/activity]
2. Return PluginSession list via getSessions()
3. Implement terminal jump via activateTerminal()

Reference:
- Template: https://github.com/tianqixinxi/meee2/tree/main/plugin-template
- Docs: https://github.com/tianqixinxi/meee2/blob/main/docs/PLUGIN_DEVELOPMENT.md`;

    navigator.clipboard.writeText(prompt).then(() => {
        const btn = document.querySelector('.plugin-code-preview .copy-btn');
        const originalText = btn.textContent;
        btn.textContent = 'Copied!';
        btn.style.color = '#22c55e';

        setTimeout(() => {
            btn.textContent = originalText;
            btn.style.color = '';
        }, 2000);
    }).catch(err => {
        console.error('Failed to copy:', err);
    });
}

// Add parallax effect to hero
window.addEventListener('scroll', () => {
    const hero = document.querySelector('.hero');
    const scrolled = window.pageYOffset;

    if (hero && scrolled < window.innerHeight) {
        const heroVisual = document.querySelector('.hero-visual');
        if (heroVisual) {
            heroVisual.style.transform = `translateY(${scrolled * 0.1}px)`;
        }
    }
});

// Add typing effect to hero title (optional)
function typeWriter(element, text, speed = 50) {
    let i = 0;
    element.textContent = '';

    function type() {
        if (i < text.length) {
            element.textContent += text.charAt(i);
            i++;
            setTimeout(type, speed);
        }
    }

    type();
}

// Dynamic Island hover effect
const islandMockup = document.querySelector('.island-mockup');
if (islandMockup) {
    islandMockup.addEventListener('mouseenter', () => {
        const compact = document.querySelector('.island.compact');
        const expanded = document.querySelector('.island.expanded');

        if (compact && expanded) {
            compact.style.opacity = '0';
            compact.style.transform = 'scale(0.95)';
            expanded.style.opacity = '1';
            expanded.style.transform = 'scale(1)';
        }
    });

    islandMockup.addEventListener('mouseleave', () => {
        const compact = document.querySelector('.island.compact');
        const expanded = document.querySelector('.island.expanded');

        if (compact && expanded) {
            compact.style.opacity = '1';
            compact.style.transform = 'scale(1)';
            expanded.style.opacity = '0.5';
            expanded.style.transform = 'scale(0.95)';
        }
    });
}

// Initialize expanded island as hidden
document.addEventListener('DOMContentLoaded', () => {
    const expanded = document.querySelector('.island.expanded');
    if (expanded) {
        expanded.style.opacity = '0.5';
        expanded.style.transform = 'scale(0.95)';
        expanded.style.transition = 'all 0.3s ease';
    }

    const compact = document.querySelector('.island.compact');
    if (compact) {
        compact.style.transition = 'all 0.3s ease';
    }
});