import { exec, spawn, toast } from 'kernelsu-alt';
import { config } from './index.js'

const moddir = '/data/adb/modules/mountify';

export function loadVersion() {
    exec(`grep "^version=" ${moddir}/module.prop | cut -d= -f2`).then((result) => {
        if (result.errno !== 0) return;
        document.getElementById('version').innerHTML = result.stdout.trim();
    }).catch(() => {});
}

export async function loadConfig() {
    try {
        const response = await fetch('./config.sh');
        if (!response.ok) throw new Error('response failed');
        const conf = (await response.text())
            .split('\n')
            .filter(line => line.trim() !== '' && !line.startsWith('#'))
            .map(line => line.trim())
            .map(line => {
                const eq = line.indexOf('=');
                if (eq === -1) return null;
                return [line.slice(0, eq).trim(), line.slice(eq + 1).trim()];
            })
            .filter(Boolean)
            .reduce((acc, [key, value]) => {
                if (key && value) {
                    if (value.startsWith('"') && value.endsWith('"')) {
                        acc[key] = value.substring(1, value.length - 1);
                    } else {
                        const num = parseInt(value, 10);
                        acc[key] = Number.isNaN(num) ? value : num;
                    }
                }
                return acc;
            }, {});
        return conf;
    } catch (e) {
        exec(`
            CONFIG="/data/adb/mountify/config.sh"
            if [ -f "/data/adb/mountify/config.sh" ]; then
                CONFIG="/data/adb/mountify/config.sh"
            fi
            ln -sfn "$CONFIG" "${moddir}/webroot/config.sh"
        `).then((result) => {
            if (result.errno !== 0) {
                toast("Failed to load config");
                return;
            }
            window.location.reload();
        }).catch(() => {});
    }
}

export async function loadConfigMetadata() {
    try {
        const response = await fetch('./config_mountify.json');
        if (!response.ok) {
            toast('Failed to load config_mountify.json');
            return {};
        }
        return await response.json();
    } catch (e) {
        toast('Failed to load config_mountify.json: ' + e);
        return {};
    }
}

export async function writeConfig() {
    const oldConfig = await loadConfig();
    if (!oldConfig) {
        toast('Failed to save config!');
        return;
    }

    const commands = [];
    for (const key in config) {
        if (Object.prototype.hasOwnProperty.call(config, key) && Object.prototype.hasOwnProperty.call(oldConfig, key)) {
            if (config[key] !== oldConfig[key]) {
                let value = config[key];
                // never write NaN back into the config
                if (typeof value === 'number' && !Number.isFinite(value)) {
                    value = oldConfig[key];
                }
                let command;
                if (typeof value === 'string') {
                    // strip characters that would break the sed replacement or shell quoting
                    const sanitized = value.replace(/["'`$\n\r\\]/g, '');
                    if (sanitized !== value) {
                        toast(`Unsupported characters removed from ${key}`);
                        value = sanitized;
                        config[key] = sanitized;
                    }
                    // escape sed replacement metacharacters (& and the | delimiter)
                    const sedSafe = value.replace(/[&|]/g, (m) => '\\' + m);
                    command = `sed -i 's|^${key}=.*|${key}="${sedSafe}"|'`;
                } else {
                    command = `sed -i 's|^${key}=.*|${key}=${value}|'`;
                }
                commands.push(command + ` "$(realpath ${moddir}/webroot/config.sh)"`);
            }
        }
    }

    if (commands.length > 0) {
        let stderr = [];
        const command = commands.join(' && ');
        const result = spawn(command);
        result.stderr.on('data', (data) => {
            stderr.push(data);
        });
        result.on('exit', (code) => {
            if (code !== 0) {
                toast('Error saving config: ' + stderr.join(' '));
            }
        });
    }
}
