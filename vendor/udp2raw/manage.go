package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/AlecAivazis/survey/v2"
)

var managedUnitName = regexp.MustCompile(`^azumi(udp|fec)_(kharej[1-9][0-9]*|iran-[1-9][0-9]*)\.service$`)
var managedExec = regexp.MustCompile(`(?m)^ExecStart=([^\r\n]+)`)

type portUnit struct {
	name, content string
}

func unitEndpoint(content, flag string) (string, int, error) {
	command := managedExec.FindStringSubmatch(content)
	if len(command) != 2 {
		return "", 0, fmt.Errorf("missing ExecStart")
	}
	match := regexp.MustCompile(`(?:^|\s)-` + flag + `\s*(\S+)`).FindStringSubmatch(command[1])
	if len(match) != 2 {
		return "", 0, fmt.Errorf("missing -%s endpoint", flag)
	}
	host, port, err := net.SplitHostPort(match[1])
	if err != nil {
		return "", 0, fmt.Errorf("unsupported -%s endpoint", flag)
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return "", 0, fmt.Errorf("invalid -%s port", flag)
	}
	return host, n, nil
}

func withUnitPort(content, flag string, port int) (string, error) {
	if port < 1 || port > 65535 {
		return "", fmt.Errorf("ports must be 1-65535")
	}
	host, _, err := unitEndpoint(content, flag)
	if err != nil {
		return "", err
	}
	command := managedExec.FindStringSubmatchIndex(content)
	line := content[command[2]:command[3]]
	endpoint := regexp.MustCompile(`(?:^|\s)-` + flag + `\s*(\S+)`).FindStringSubmatchIndex(line)
	line = line[:endpoint[2]] + net.JoinHostPort(host, strconv.Itoa(port)) + line[endpoint[3]:]
	return content[:command[2]] + line + content[command[3]:], nil
}

func readPortUnit(directory, name string) (portUnit, error) {
	if !managedUnitName.MatchString(name) {
		return portUnit{}, fmt.Errorf("unsupported service name")
	}
	path := filepath.Join(directory, name)
	info, err := os.Lstat(path)
	if err != nil {
		return portUnit{}, err
	}
	if !info.Mode().IsRegular() {
		return portUnit{}, fmt.Errorf("service must be a regular file")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return portUnit{}, err
	}
	for _, flag := range []string{"l", "r"} {
		if _, _, err := unitEndpoint(string(content), flag); err != nil {
			return portUnit{}, err
		}
	}
	return portUnit{name, string(content)}, nil
}

func portPair(directory, name string) ([]portUnit, error) {
	raw, err := readPortUnit(directory, name)
	if err != nil {
		return nil, err
	}
	units := []portUnit{raw}
	fecName := strings.Replace(name, "azumiudp_", "azumifec_", 1)
	if _, err := os.Lstat(filepath.Join(directory, fecName)); !os.IsNotExist(err) {
		fec, err := readPortUnit(directory, fecName)
		if err != nil {
			return nil, err
		}
		units = append(units, fec)
	}
	return units, nil
}

// Change both sides of the local FEC link together. Remote hosts, credentials,
// raw mode, IPv6 addresses and optional transport flags remain byte-for-byte.
func remapPortPair(units []portUnit, tunnel, wireguard, fec int) ([]portUnit, error) {
	result := append([]portUnit(nil), units...)
	if len(result) < 1 || len(result) > 2 {
		return nil, fmt.Errorf("invalid service pair")
	}
	iran := strings.Contains(result[0].name, "_iran-")
	rawListen, rawRemote := tunnel, wireguard
	if iran {
		rawListen, rawRemote = wireguard, tunnel
	}
	if len(result) == 2 && !iran {
		rawRemote = fec
	}
	set := func(i int, flag string, port int) error {
		content, err := withUnitPort(result[i].content, flag, port)
		if err == nil {
			result[i].content = content
		}
		return err
	}
	if err := set(0, "l", rawListen); err != nil {
		return nil, err
	}
	if err := set(0, "r", rawRemote); err != nil {
		return nil, err
	}
	if len(result) == 2 {
		if fec == rawListen {
			return nil, fmt.Errorf("FEC and UDP2RAW listen ports must differ")
		}
		if !iran && (fec == wireguard || tunnel == wireguard) {
			return nil, fmt.Errorf("local tunnel ports must differ from WireGuard")
		}
		if err := set(1, "l", fec); err != nil {
			return nil, err
		}
		if err := set(1, "r", wireguard); err != nil {
			return nil, err
		}
	} else if !iran && tunnel == wireguard {
		return nil, fmt.Errorf("local tunnel and WireGuard ports must differ")
	}
	return result, nil
}

func nextPortPair(directory string, units []portUnit) ([]portUnit, error) {
	prefix := "kharej"
	if strings.Contains(units[0].name, "_iran-") {
		prefix = "iran-"
	}
	for index := 1; index <= 65535; index++ {
		suffix := prefix + strconv.Itoa(index) + ".service"
		free := true
		for _, kind := range []string{"udp", "fec"} {
			_, err := os.Lstat(filepath.Join(directory, "azumi"+kind+"_"+suffix))
			if !os.IsNotExist(err) {
				free = false
			}
		}
		if !free {
			continue
		}
		result := append([]portUnit(nil), units...)
		for i := range result {
			kind := "udp"
			if i == 1 {
				kind = "fec"
			}
			old := strings.TrimSuffix(result[i].name, ".service")
			result[i].name = "azumi" + kind + "_" + suffix
			result[i].content = strings.ReplaceAll(result[i].content, "Description="+old+" Service", "Description="+strings.TrimSuffix(result[i].name, ".service")+" Service")
		}
		return result, nil
	}
	return nil, fmt.Errorf("no free configuration number")
}

func writePortUnit(directory string, unit portUnit) error {
	file, err := os.CreateTemp(directory, ".udp2raw-port-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.WriteString(unit.content); err != nil {
		file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), filepath.Join(directory, unit.name))
}

type portSystemctl func(...string) error

// A failed apply restores both unit files and their previous running state.
func applyPortPair(directory string, before, after []portUnit, adding bool, run portSystemctl) (err error) {
	active := make(map[string]bool)
	for _, unit := range before {
		active[unit.name] = run("is-active", "--quiet", unit.name) == nil
	}
	written := []portUnit{}
	defer func() {
		if err == nil {
			return
		}
		var failures []string
		check := func(e error) {
			if e != nil {
				failures = append(failures, e.Error())
			}
		}
		if adding {
			for _, unit := range written {
				check(run("disable", "--now", unit.name))
				check(os.Remove(filepath.Join(directory, unit.name)))
			}
		} else {
			for _, unit := range before {
				check(run("stop", unit.name))
			}
			for _, unit := range before {
				check(writePortUnit(directory, unit))
			}
		}
		check(run("daemon-reload"))
		if !adding {
			for _, unit := range before {
				if active[unit.name] {
					check(run("start", unit.name))
				}
			}
		}
		if len(failures) > 0 {
			err = fmt.Errorf("%w; rollback needs attention: %s", err, strings.Join(failures, "; "))
		}
	}()
	if !adding {
		for _, unit := range before {
			if err = run("stop", unit.name); err != nil {
				return err
			}
		}
	}
	for _, unit := range after {
		if _, e := os.Lstat(filepath.Join(directory, unit.name)); adding && !os.IsNotExist(e) {
			return fmt.Errorf("target service already exists")
		}
		if err = writePortUnit(directory, unit); err != nil {
			return err
		}
		written = append(written, unit)
	}
	if err = run("daemon-reload"); err != nil {
		return err
	}
	for _, unit := range after {
		if adding {
			err = run("enable", "--now", unit.name)
		} else if active[unit.name] {
			err = run("start", unit.name)
		}
		if err != nil {
			return err
		}
	}
	for _, unit := range after {
		if adding || active[unit.name] {
			if err = run("is-active", "--quiet", unit.name); err != nil {
				return err
			}
		}
	}
	return nil
}

func checkPortListeners(directory string, before, after []portUnit, adding bool) error {
	ignore := map[string]bool{}
	if !adding {
		for _, unit := range before {
			ignore[unit.name] = true
		}
	}
	ports := map[int]bool{}
	for _, unit := range after {
		_, p, err := unitEndpoint(unit.content, "l")
		if err != nil {
			return err
		}
		ports[p] = true
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !managedUnitName.MatchString(entry.Name()) || ignore[entry.Name()] {
			continue
		}
		unit, err := readPortUnit(directory, entry.Name())
		if err != nil {
			return fmt.Errorf("cannot inspect %s: %w", entry.Name(), err)
		}
		_, p, _ := unitEndpoint(unit.content, "l")
		if ports[p] {
			return fmt.Errorf("listen port %d is reserved by %s", p, unit.name)
		}
	}
	oldPorts := map[int]bool{}
	if !adding {
		for _, unit := range before {
			_, p, _ := unitEndpoint(unit.content, "l")
			oldPorts[p] = true
		}
	}
	for p := range ports {
		if oldPorts[p] {
			continue
		}
		output, err := exec.Command("ss", "-H", "-ltnu", "sport = :"+strconv.Itoa(p)).Output()
		if err != nil {
			return fmt.Errorf("cannot check listen port %d: %w", p, err)
		}
		if len(strings.TrimSpace(string(output))) > 0 {
			return fmt.Errorf("listen port %d is occupied", p)
		}
	}
	return nil
}

func managePortMenu(adding bool) {
	if err := managePortPair("/etc/systemd/system", adding); err != nil {
		displayError(err.Error())
	}
}

func managePortPair(directory string, adding bool) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	options := []string{}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "azumiudp_") && managedUnitName.MatchString(entry.Name()) {
			options = append(options, entry.Name())
		}
	}
	if len(options) == 0 {
		return fmt.Errorf("no existing UDP2RAW configuration; run initial setup first")
	}
	sort.Strings(options)
	options = append(options, "Back")
	var selected string
	message := "Select configuration to edit ports:"
	if adding {
		message = "Select existing configuration as template for an additional port:"
	}
	if err := survey.AskOne(&survey.Select{Message: message, Options: options}, &selected); err != nil {
		return err
	}
	if selected == "Back" {
		return nil
	}
	before, err := portPair(directory, selected)
	if err != nil {
		return err
	}
	_, listen, _ := unitEndpoint(before[0].content, "l")
	_, remote, _ := unitEndpoint(before[0].content, "r")
	tunnel, wireguard, fec := listen, remote, 0
	iran := strings.Contains(selected, "_iran-")
	if iran {
		tunnel, wireguard = remote, listen
	}
	if len(before) == 2 {
		_, fec, _ = unitEndpoint(before[1].content, "l")
		if !iran {
			_, wireguard, _ = unitEndpoint(before[1].content, "r")
		}
	}
	promptPort := func(label string, current *int) error {
		var value string
		if err := survey.AskOne(&survey.Input{Message: label, Default: strconv.Itoa(*current)}, &value, survey.WithValidator(func(v interface{}) error {
			n, err := strconv.Atoi(fmt.Sprint(v))
			if err != nil || n < 1 || n > 65535 {
				return fmt.Errorf("enter a port from 1 to 65535")
			}
			return nil
		})); err != nil {
			return err
		}
		*current, _ = strconv.Atoi(value)
		return nil
	}
	if err := promptPort("Tunnel port (use the same value on Iran and Outside):", &tunnel); err != nil {
		return err
	}
	label := "WireGuard destination UDP port on this server:"
	if iran {
		label = "Local UDP2RAW entry/link port:"
	}
	if err := promptPort(label, &wireguard); err != nil {
		return err
	}
	if len(before) == 2 {
		label = "Local FEC link port:"
		if iran {
			label = "WireGuard client UDP entry port (FEC):"
		}
		if err := promptPort(label, &fec); err != nil {
			return err
		}
	}
	after, err := remapPortPair(before, tunnel, wireguard, fec)
	if err != nil {
		return err
	}
	if adding {
		after, err = nextPortPair(directory, after)
		if err != nil {
			return err
		}
	}
	if err := checkPortListeners(directory, before, after, adding); err != nil {
		return err
	}
	fmt.Println("Credentials, remote address and raw mode are inherited. Configure matching ports on the other server too.")
	for _, unit := range after {
		_, l, _ := unitEndpoint(unit.content, "l")
		_, r, _ := unitEndpoint(unit.content, "r")
		fmt.Printf("%s: listen %d -> destination %d\n", unit.name, l, r)
	}
	var confirm bool
	if err := survey.AskOne(&survey.Confirm{Message: "Apply these ports?", Default: false}, &confirm); err != nil {
		return err
	}
	if !confirm {
		return nil
	}
	run := func(args ...string) error {
		if err := exec.Command("systemctl", args...).Run(); err != nil {
			return fmt.Errorf("systemctl %s failed: %w", strings.Join(args, " "), err)
		}
		return nil
	}
	if err := applyPortPair(directory, before, after, adding, run); err != nil {
		return err
	}
	displayCheckmark("Port configuration saved. Allow the new ports in your server/provider firewall and update WireGuard endpoints if changed.")
	if adding {
		fmt.Println("Existing reset schedules are unchanged; include the new service names in /etc/udp.sh if you use scheduled resets.")
	}
	return nil
}
