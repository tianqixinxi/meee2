// meee2 Landing Page - JavaScript

document.addEventListener('DOMContentLoaded', function() {
    // Initialize scroll animations
    initScrollAnimations();

    // Initialize smooth scroll
    initSmoothScroll();

    // Initialize navigation highlight
    initNavHighlight();
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